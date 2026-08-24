// signin — TRAE 纯签到工具：遍历 auths/trae-*.json 全部账号，
// 自动刷新过期 token，逐个签到并查询积分。
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"trae-signin/internal/auth"
	"trae-signin/internal/upstream"
)

type row struct {
	file     string
	uid      string
	nick     string
	status   string
	detail   string
	remain   float64
	hasRem   bool
	expiring []upstream.ExpiringPack
}

func main() {
	dir := "auths"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	files, err := filepath.Glob(filepath.Join(dir, "trae-*.json"))
	if err != nil || len(files) == 0 {
		fmt.Fprintf(os.Stderr, "❌ 在 %s 中没有找到 trae-*.json 凭证文件\n", dir)
		fmt.Fprintf(os.Stderr, "   请先运行 login.sh 登录账号\n")
		os.Exit(1)
	}
	sort.Strings(files)
	up := upstream.New()

	var rows []row
	okN, alreadyN, failN := 0, 0, 0

	for _, f := range files {
		r := row{file: filepath.Base(f)}
		raw, err := os.ReadFile(f)
		if err != nil {
			r.status, r.detail = "LOAD_ERR", err.Error()
			rows = append(rows, r)
			failN++
			continue
		}
		a, err := auth.Parse(raw)
		if err != nil {
			r.status, r.detail = "LOAD_ERR", err.Error()
			rows = append(rows, r)
			failN++
			continue
		}
		a.FilePath = f
		r.uid, r.nick = a.UID, a.Nickname

		// 刷新过期 token（2h 缓冲）
		if a.NeedsRefresh(2 * time.Hour) {
			fmt.Printf("🔄 %s token 即将过期，正在刷新...\n", r.uid)
			if err := up.RefreshToken(a); err != nil {
				r.status = "FAIL"
				r.detail = "refresh: " + short(err.Error())
				rows = append(rows, r)
				failN++
				continue
			}
			_ = a.SaveAtomic()
			fmt.Printf("   ✅ token 刷新成功\n")
		}

		// 签到
		checkedIn, _, enable, serr := up.CheckinStatus(a)
		switch {
		case serr != nil:
			if isAlready(serr.Error()) {
				r.status = "ALREADY"
				r.detail = short(serr.Error())
				alreadyN++
			} else {
				r.status = "FAIL"
				r.detail = short(serr.Error())
				failN++
			}
		case checkedIn:
			r.status = "ALREADY"
			r.detail = "今日已签到"
			alreadyN++
		case !enable:
			r.status = "FAIL"
			r.detail = "签到已禁用"
			failN++
		default:
			st, detail := doCheckinWithRetry(up, a, r.uid)
			switch st {
			case "OK":
				r.status = "✅ OK"
				okN++
			case "ALREADY":
				r.status, r.detail = "ALREADY", detail
				alreadyN++
			default:
				r.status, r.detail = "FAIL", detail
				failN++
			}
		}

		// 查积分（同时获取 7 天内将过期的权益包）
		if remain, expiring, qerr := up.UserEntUsage(a); qerr == nil {
			r.remain, r.hasRem, r.expiring = remain, true, expiring
		}
		rows = append(rows, r)
	}

	// 报告
	fmt.Println()
	fmt.Println("┌──────────────────────────────────────┬───────────────┬──────────────┬──────────┬──────────────────────────────────────┐")
	fmt.Println("│ UID                                  │ 昵称          │ 状态         │ 积分     │ 详情                                 │")
	fmt.Println("├──────────────────────────────────────┼───────────────┼──────────────┼──────────┼──────────────────────────────────────┤")
	for _, r := range rows {
		remain := "-"
		if r.hasRem {
			remain = fmt.Sprintf("%.2f", r.remain)
		}
		fmt.Printf("│ %-36s │ %-13s │ %-12s │ %-8s │ %-36s │\n",
			trunc(r.uid, 36), trunc(r.nick, 13), r.status, remain, trunc(r.detail, 36))
	}
	fmt.Println("└──────────────────────────────────────┴───────────────┴──────────────┴──────────┴──────────────────────────────────────┘")
	fmt.Println()
	fmt.Printf("📊 总计=%d  签到成功=%d  已签=%d  失败=%d\n", len(rows), okN, alreadyN, failN)

	// 输出 7 天内将过期的积分包（格式化标记行，供 signin.sh 解析进通知）
	for _, r := range rows {
		for _, p := range r.expiring {
			fmt.Printf("EXPIRE_HINT|%s|%s|%.2f|%s\n",
				trunc(r.nick, 13), p.Desc, p.Remain,
				time.Unix(p.ExpireAt, 0).Format("2006-01-02 15:04"))
		}
	}

	// 输出失败详情完整内容（表格中详情列会被截断，供 signin.sh 解析进通知）
	for _, r := range rows {
		if strings.Contains(r.status, "FAIL") && r.detail != "" {
			fmt.Printf("FAIL_DETAIL|%s|%s\n", trunc(r.nick, 13), r.detail)
		}
	}
}

func isAlready(msg string) bool {
	s := strings.ToLower(msg)
	return strings.Contains(s, "已签到") ||
		strings.Contains(s, "already check") ||
		strings.Contains(s, "already checked")
}

// verifyCheckin 二次验证签到是否真正生效：claim 接口返回 HTTP 200 不代表业务成功，
// 需重新查询签到状态，确认 checked_in 已变为 true 才认定签到成功。
// 最多查询 3 次（首次等 1 秒，之后每次间隔 2 秒），
// 全部查询均为"未签到"才判定未生效，规避服务端状态落库延迟导致的误判。
func verifyCheckin(up *upstream.Client, a *auth.Auth) bool {
	for i := 0; i < 3; i++ {
		if i == 0 {
			time.Sleep(1 * time.Second)
		} else {
			time.Sleep(2 * time.Second)
		}
		checked, _, _, verr := up.CheckinStatus(a)
		if verr != nil {
			continue // 查询出错，继续重试
		}
		if checked {
			return true
		}
		// 查到未签到：可能是落库延迟，继续查询
	}
	return false
}

// doCheckinWithRetry 执行签到，含拥堵退避重试与生效验证。
// 策略：业务码 9074（参与人数过多）或网络错误 → 指数退避（5/10/20/40s）后重试；
// claim 成功但二次验证未生效 → 同样重试（签到接口幂等，已签会返回已签错误）；
// 其他业务错误快速失败。最多尝试 5 次。
// 返回最终状态 "OK"/"ALREADY"/"FAIL" 与详情（完整原因，供通知展示）。
func doCheckinWithRetry(up *upstream.Client, a *auth.Auth, uid string) (string, string) {
	const maxAttempts = 5
	var lastResp []byte
	lastErr := "未知错误"
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if attempt > 1 {
			// 指数退避：5s、10s、20s、40s
			wait := time.Duration(5<<(attempt-2)) * time.Second
			fmt.Printf("   ⏳ %s 第 %d/%d 次尝试（退避 %v 后重试）...\n", uid, attempt, maxAttempts, wait)
			time.Sleep(wait)
		}
		resp, cerr := up.CheckinClaim(a)
		lastResp = resp
		if cerr == nil {
			fmt.Printf("   📨 %s claim 响应: %s\n", uid, truncateBody(string(resp)))
			if verifyCheckin(up, a) {
				return "OK", ""
			}
			// claim 返回成功但签到未生效：可能是静默失败，退避后重新签到
			lastErr = "签到未生效（claim 成功但状态查询仍为未签到）"
			continue
		}
		lastErr = cerr.Error()
		var biz *upstream.ClaimBizError
		switch {
		case errors.As(cerr, &biz) && biz.Code == upstream.ClaimCodeBusy:
			// 服务端拥堵，退避重试
			fmt.Printf("   🌀 %s 服务端拥堵（%s）\n", uid, cerr.Error())
			continue
		case isAlready(cerr.Error()):
			return "ALREADY", "今日已签到"
		case errors.As(cerr, &biz):
			// 其他业务错误：快速失败，完整原因进入通知
			return "FAIL", cerr.Error()
		default:
			// HTTP 层错误：可能是瞬时故障，退避重试
			fmt.Printf("   ⚠️ %s 网络错误（%s），稍后重试\n", uid, short(cerr.Error()))
			continue
		}
	}
	return "FAIL", lastErr + "｜最后响应: " + truncateBody(string(lastResp))
}

// truncateBody 截断响应体到指定长度，用于日志输出，避免刷屏。
func truncateBody(s string) string {
	s = strings.ReplaceAll(strings.TrimSpace(s), "\n", " ")
	if len(s) > 300 {
		return s[:300] + "..."
	}
	return s
}

func trunc(s string, n int) string {
	// 按 rune 截断，避免按字节截断多字节中文字符产生乱码("?")
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

func short(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > 60 {
		return s[:60]
	}
	return s
}
