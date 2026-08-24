#!/usr/bin/env bash
# signin.sh — TRAE 批量签到脚本，签到后通过 Bark / 钉钉推送通知
set -e
cd "$(dirname "$0")"

BARK_URL="${BARK_URL:-https://api.day.app/Av8DkzMpStcsmsW3KfqEMc}"
# 钉钉自定义机器人配置（可选，配置后启用钉钉通知）
DINGTALK_WEBHOOK="${DINGTALK_WEBHOOK:-}"
DINGTALK_SECRET="${DINGTALK_SECRET:-}"

go build -o signin_bin ./cmd/signin

# 执行签到并捕获输出
SIGNIN_OUTPUT=$(./signin_bin "${1:-auths}" 2>&1)
SIGNIN_EXIT=$?

echo "$SIGNIN_OUTPUT"

# 提取关键信息用于 Bark 推送
TOTAL=$(echo "$SIGNIN_OUTPUT" | grep -oP '总计=\K\d+' || echo "?")
OK=$(echo "$SIGNIN_OUTPUT" | grep -oP '签到成功=\K\d+' || echo "?")
ALREADY=$(echo "$SIGNIN_OUTPUT" | grep -oP '已签=\K\d+' || echo "?")
FAIL=$(echo "$SIGNIN_OUTPUT" | grep -oP '失败=\K\d+' || echo "?")

# 提取每个账号的信息
ACCOUNTS=""
while IFS= read -r line; do
    if echo "$line" | grep -qP '│\s+\d+'; then
        uid=$(echo "$line" | sed 's/│/\n/g' | sed -n '2p' | xargs)
        nick=$(echo "$line" | sed 's/│/\n/g' | sed -n '3p' | xargs)
        status=$(echo "$line" | sed 's/│/\n/g' | sed -n '4p' | xargs)
        credits=$(echo "$line" | sed 's/│/\n/g' | sed -n '5p' | xargs)
        ACCOUNTS="${ACCOUNTS}${nick} ${status} 积分${credits}\n"
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

BODY="总计${TOTAL} | 成功${OK} | 已签${ALREADY} | 失败${FAIL}\n${ACCOUNTS}"

# 发送 Bark 通知
curl -s -X POST "$BARK_URL/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TITLE'))")/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$BODY'))")" > /dev/null 2>&1 || true

echo "📲 Bark 通知已发送"

# 发送钉钉通知（配置了 DINGTALK_WEBHOOK 时启用）
if [ -n "$DINGTALK_WEBHOOK" ]; then
    # 构造钉钉 markdown 消息内容
    DING_BODY="### ${TITLE}\n\n**总计** ${TOTAL} | **成功** ${OK} | **已签** ${ALREADY} | **失败** ${FAIL}\n\n${ACCOUNTS}"
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
        -d "$(DING_BODY="$DING_BODY" python3 -c "import json,os; print(json.dumps({'msgtype':'markdown','markdown':{'title':'TRAE 签到','text':os.environ['DING_BODY']}}, ensure_ascii=False))")" \
        > /dev/null 2>&1 || true
    echo "📮 钉钉通知已发送"
fi
