#!/usr/bin/env bash
# signin.sh — TRAE 批量签到脚本，签到后通过 Bark / 钉钉推送通知
set -e
cd "$(dirname "$0")"

BARK_URL="${BARK_URL:-https://api.day.app/Av8DkzMpStcsmsW3KfqEMc}"
# 钉钉自定义机器人配置（可选，配置后启用钉钉通知）
DINGTALK_WEBHOOK="${DINGTALK_WEBHOOK:-}"
DINGTALK_SECRET="${DINGTALK_SECRET:-}"

go build -o signin_bin ./cmd/signin

# 格式化积分为千分位两位小数（如 4776.08 → 4,776.08），非法输入原样返回
fmt_credits() {
  V="$1" python3 -c "import os
try:
    print('{:,.2f}'.format(float(os.environ['V'])))
except Exception:
    print(os.environ['V'])" 2>/dev/null || printf '%s' "$1"
}

# 执行签到并捕获输出
SIGNIN_OUTPUT=$(./signin_bin "${1:-auths}" 2>&1)
SIGNIN_EXIT=$?

echo "$SIGNIN_OUTPUT"

# 提取关键信息用于 Bark 推送
TOTAL=$(echo "$SIGNIN_OUTPUT" | grep -oP '总计=\K\d+' || echo "?")
OK=$(echo "$SIGNIN_OUTPUT" | grep -oP '签到成功=\K\d+' || echo "?")
ALREADY=$(echo "$SIGNIN_OUTPUT" | grep -oP '已签=\K\d+' || echo "?")
FAIL=$(echo "$SIGNIN_OUTPUT" | grep -oP '失败=\K\d+' || echo "?")

# 提取每个账号的信息（纯文本版给 Bark，markdown 版给钉钉）
# 注意：bash 双引号内 \n 是字面两字符，此处必须用真实换行，否则通知显示为 "\n" 字样
ACCOUNTS=""
ACCOUNTS_MD=""
idx=0
while IFS= read -r line; do
    if echo "$line" | grep -qP '│\s+\d+'; then
        nick=$(echo "$line" | sed 's/│/\n/g' | sed -n '3p' | xargs)
        status=$(echo "$line" | sed 's/│/\n/g' | sed -n '4p' | xargs)
        credits=$(echo "$line" | sed 's/│/\n/g' | sed -n '5p' | xargs)
        # 状态码映射为中文，提升可读性
        case "$status" in
            *OK*)       status_cn="✅ 签到成功" ;;
            *ALREADY*)  status_cn="🟡 今日已签" ;;
            *FAIL*)     status_cn="❌ 签到失败" ;;
            *LOAD_ERR*) status_cn="⚠️ 读取失败" ;;
            *)          status_cn="$status" ;;
        esac
        idx=$((idx+1))
        credits_fmt=$(fmt_credits "$credits")
        ACCOUNTS="${ACCOUNTS}${idx}. ${nick}
${status_cn} ｜ 💰 ${credits_fmt}

"
        ACCOUNTS_MD="${ACCOUNTS_MD}**${idx}. ${nick}**
> ${status_cn}　｜　💰 剩余积分 **${credits_fmt}**

"
    fi
done <<< "$SIGNIN_OUTPUT"

# 构建 Bark 推送内容
TITLE="TRAE 签到"
if [ "$SIGNIN_EXIT" -eq 0 ]; then
    if [ "$OK" -gt 0 ] 2>/dev/null; then
        TITLE="✅ TRAE 签到成功"
    elif [ "$FAIL" -gt 0 ] 2>/dev/null; then
        TITLE="⚠️ TRAE 签到异常"
    else
        TITLE="📌 TRAE 已签到"
    fi
else
    TITLE="❌ TRAE 签到失败"
fi

# 公共摘要与时间（真实换行构造，避免 \n 字面量）
NOW_CN=$(date '+%Y-%m-%d %H:%M')
SUMMARY="📊 账号 ${TOTAL} ｜ ✅ 成功 ${OK} ｜ 🟡 已签 ${ALREADY} ｜ ❌ 失败 ${FAIL}"

BODY="${NOW_CN}
${SUMMARY}

${ACCOUNTS}"

# 发送 Bark 通知（经环境变量传值并剔除非法 surrogate，避免含 emoji 昵称触发 UnicodeEncodeError）
curl -s -X POST "$BARK_URL/$(TITLE="$TITLE" python3 -c "import os,urllib.parse; s=os.environ['TITLE'].encode('utf-8','replace').decode('utf-8'); print(urllib.parse.quote(s, safe=''))")/$(BODY="$BODY" python3 -c "import os,urllib.parse; s=os.environ['BODY'].encode('utf-8','replace').decode('utf-8'); print(urllib.parse.quote(s, safe=''))")" > /dev/null 2>&1 || true

echo "📲 Bark 通知已发送"

# 发送钉钉通知（配置了 DINGTALK_WEBHOOK 时启用）
if [ -n "$DINGTALK_WEBHOOK" ]; then
    # 构造钉钉 markdown 消息内容（真实换行）
    DING_BODY="### ${TITLE}

**🕒 ${NOW_CN}**

> ${SUMMARY}

**👤 账号明细**

${ACCOUNTS_MD}"
    # 生成加签参数（timestamp + secret 的 HmacSHA256 签名）
    DING_PARAMS=$(DINGTALK_SECRET="$DINGTALK_SECRET" python3 - <<'PYEOF'
import base64, hashlib, hmac, os, time, urllib.parse
secret = os.environ.get("DINGTALK_SECRET", "")
timestamp = str(round(time.time() * 1000))
if secret:
    string_to_sign = "{}\n{}".format(timestamp, secret)
    hmac_code = hmac.new(secret.encode("utf-8"), string_to_sign.encode("utf-8"), digestmod=hashlib.sha256).digest()
    sign = urllib.parse.quote_plus(base64.b64encode(hmac_code))
    print("&timestamp={}&sign={}".format(timestamp, sign))
else:
    print("")
PYEOF
)
    # 发送钉钉消息
    curl -s -X POST "${DINGTALK_WEBHOOK}${DING_PARAMS}" \
        -H 'Content-Type: application/json' \
        -d "$(DING_BODY="$DING_BODY" DING_TITLE="$TITLE" python3 -c "import json,os; s=os.environ['DING_BODY'].encode('utf-8','replace').decode('utf-8'); print(json.dumps({'msgtype':'markdown','markdown':{'title':os.environ.get('DING_TITLE','TRAE 签到'),'text':s}}, ensure_ascii=False))")" \
        > /dev/null 2>&1 || true
    echo "📮 钉钉通知已发送"
fi
