#!/usr/bin/env bash
# =============================================================================
# Claude Code × 企业微信通知 一键部署脚本
# =============================================================================
set -euo pipefail

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
ask()     { echo -e "${CYAN}[INPUT]${NC} $*"; }

# ── 默认安装路径 ───────────────────────────────────────────────────────────────
INSTALL_DIR="${HOME}/.claude/hooks/wechat_notify"
HOOK_FILE="${INSTALL_DIR}/notify_wechat.py"
SETTINGS_FILE="${HOME}/.claude/settings.json"

# =============================================================================
# Banner
# =============================================================================
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Claude Code × 企业微信通知 一键部署                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# Step 1: 获取 Webhook URL
# =============================================================================
info "Step 1/4 - 配置企业微信 Webhook URL"

# 优先读取已有环境变量
WEBHOOK_URL="${WECHAT_WEBHOOK_URL:-}"

if [[ -z "$WEBHOOK_URL" ]]; then
    ask "请输入企业微信群机器人 Webhook URL："
    ask "（格式：https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxx）"
    read -r WEBHOOK_URL
fi

if [[ -z "$WEBHOOK_URL" ]]; then
    error "Webhook URL 不能为空，请重新运行脚本"
fi

# 简单格式校验
if [[ "$WEBHOOK_URL" != https://qyapi.weixin.qq.com/cgi-bin/webhook/send* ]]; then
    warn "URL 格式看起来不像企业微信 Webhook，请确认是否正确"
    ask "是否继续？[y/N]"
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || error "已取消"
fi

success "Webhook URL 已获取"

# =============================================================================
# Step 2: 写入 notify_wechat.py
# =============================================================================
info "Step 2/4 - 安装 Hook 脚本到 ${HOOK_FILE}"

mkdir -p "$INSTALL_DIR"

cat > "$HOOK_FILE" << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
Claude Code -> 企业微信 Webhook 通知推送脚本
当 Claude Code 需要用户输入/确认时，通过企业微信群机器人推送通知。
"""

import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime


def get_webhook_url():
    url = os.environ.get("WECHAT_WEBHOOK_URL")
    if url:
        return url
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("WECHAT_WEBHOOK_URL="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def get_last_assistant_message(transcript_path: str) -> str:
    if not transcript_path or not os.path.exists(transcript_path):
        return ""
    try:
        last_msg = ""
        with open(transcript_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("type") == "assistant":
                    parts = []
                    for block in entry.get("message", {}).get("content", []):
                        if isinstance(block, str):
                            parts.append(block)
                        elif isinstance(block, dict) and block.get("type") == "text":
                            parts.append(block.get("text", ""))
                    if parts:
                        last_msg = "\n".join(parts)
        return last_msg
    except Exception:
        return ""


def build_markdown(data: dict) -> str:
    hook_event = data.get("hook_event_name", "unknown")
    session_id = data.get("session_id", "N/A")
    cwd = data.get("cwd", "N/A")
    transcript_path = data.get("transcript_path", "")
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    if hook_event == "Notification":
        notification_type = data.get("notification_type", "unknown")
        message = data.get("message", "")
        title = data.get("title", "")
        type_labels = {
            "permission_prompt": "🔐 权限确认",
            "idle_prompt": "⏳ 等待输入",
            "elicitation_dialog": "💬 需要选择",
            "auth_success": "✅ 认证成功",
        }
        type_label = type_labels.get(notification_type, f"📢 {notification_type}")
        last_reply = get_last_assistant_message(transcript_path)
        if last_reply:
            if len(last_reply) > 500:
                last_reply = last_reply[:500] + "\n..."
            message = message + f"\n\n**Claude 最近回复**:\n{last_reply}" if message else last_reply
    elif hook_event == "Stop":
        type_label = "⏸️ Claude 已停止，等待输入"
        title = ""
        message = data.get("last_assistant_message", "")
        if not message:
            message = get_last_assistant_message(transcript_path)
        if len(message) > 500:
            message = message[:500] + "\n..."
    else:
        type_label = f"📢 {hook_event}"
        title = ""
        message = json.dumps(data, ensure_ascii=False, indent=2)[:500]

    lines = [
        f"## {type_label}",
        f"> **会话 ID**: {session_id}",
        f"> **工作目录**: {cwd}",
        f"> **时间**: {now}",
    ]
    if title:
        lines.append(f"\n**标题**: {title}")
    if message:
        lines.append(f"\n**详情**:\n{message}")
    lines.append(f"\n<font color=\"warning\">请回到终端处理</font>")

    return "\n".join(lines)


def send_wechat(webhook_url: str, markdown_content: str):
    payload = {
        "msgtype": "markdown",
        "markdown": {"content": markdown_content}
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            if result.get("errcode") != 0:
                print(f"企业微信返回错误: {result}", file=sys.stderr)
    except urllib.error.URLError as e:
        print(f"发送失败: {e}", file=sys.stderr)


def main():
    webhook_url = get_webhook_url()
    if not webhook_url:
        print("未配置 WECHAT_WEBHOOK_URL，跳过通知", file=sys.stderr)
        sys.exit(0)
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        data = {}
    if not data:
        sys.exit(0)
    markdown = build_markdown(data)
    send_wechat(webhook_url, markdown)
    sys.exit(0)


if __name__ == "__main__":
    main()
PYTHON_EOF

chmod +x "$HOOK_FILE"
success "Hook 脚本已写入：${HOOK_FILE}"

# =============================================================================
# Step 3: 写入 .env 文件（同目录）
# =============================================================================
info "Step 3/4 - 保存 Webhook URL 到 ${INSTALL_DIR}/.env"

cat > "${INSTALL_DIR}/.env" << EOF
WECHAT_WEBHOOK_URL=${WEBHOOK_URL}
EOF
chmod 600 "${INSTALL_DIR}/.env"
success "已保存（权限已设为 600，仅本用户可读）"

# =============================================================================
# Step 4: 更新 Claude Code settings.json
# =============================================================================
info "Step 4/4 - 配置 Claude Code Hooks（${SETTINGS_FILE}）"

# 检查 python3 / jq 可用性，用于合并 JSON
MERGE_TOOL=""
if command -v python3 &>/dev/null; then
    MERGE_TOOL="python3"
elif command -v jq &>/dev/null; then
    MERGE_TOOL="jq"
fi

HOOK_COMMAND="python3 ${HOOK_FILE}"

HOOK_BLOCK=$(cat << EOF
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "${HOOK_COMMAND}"}]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "${HOOK_COMMAND}"}]
      }
    ]
  }
}
EOF
)

if [[ ! -f "$SETTINGS_FILE" ]]; then
    # 文件不存在，直接写入
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo "$HOOK_BLOCK" > "$SETTINGS_FILE"
    success "已创建 settings.json 并写入 hooks 配置"

elif [[ "$MERGE_TOOL" == "python3" ]]; then
    # 用 Python 深度合并，保留已有配置
    python3 - "$SETTINGS_FILE" "$HOOK_COMMAND" << 'PYEOF'
import json, sys

settings_path = sys.argv[1]
hook_command   = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

hook_entry = {"matcher": "", "hooks": [{"type": "command", "command": hook_command}]}

hooks = settings.setdefault("hooks", {})
for event in ("Notification", "Stop"):
    existing = hooks.setdefault(event, [])
    # 如果已存在相同 command 则跳过，避免重复
    already = any(
        any(h.get("command") == hook_command for h in e.get("hooks", []))
        for e in existing
    )
    if not already:
        existing.append(hook_entry)

with open(settings_path, "w") as f:
    json.dump(settings, f, ensure_ascii=False, indent=2)
PYEOF
    success "已合并 hooks 配置到已有 settings.json"

else
    warn "未找到 python3 或 jq，无法自动合并 settings.json"
    warn "请手动将以下内容合并到 ${SETTINGS_FILE}："
    echo ""
    echo "$HOOK_BLOCK"
    echo ""
fi

# =============================================================================
# Step 5: 发送测试通知
# =============================================================================
echo ""
info "正在发送测试通知，验证配置是否正确..."

TEST_PAYLOAD=$(cat << EOF
{
  "hook_event_name": "Notification",
  "notification_type": "idle_prompt",
  "session_id": "deploy-test",
  "cwd": "${PWD}",
  "message": "🎉 部署成功！企业微信通知已正常工作。",
  "transcript_path": ""
}
EOF
)

if WECHAT_WEBHOOK_URL="$WEBHOOK_URL" echo "$TEST_PAYLOAD" | python3 "$HOOK_FILE"; then
    success "测试通知已发送，请检查企业微信群是否收到消息"
else
    warn "测试通知发送失败，请检查 Webhook URL 是否正确"
fi

# =============================================================================
# 完成
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║               ✅ 部署完成！                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Hook 脚本：  ${CYAN}${HOOK_FILE}${NC}"
echo -e "  Webhook 配置：${CYAN}${INSTALL_DIR}/.env${NC}"
echo -e "  Claude 配置：${CYAN}${SETTINGS_FILE}${NC}"
echo ""
echo -e "  重新运行此脚本可更新 Webhook URL 或修复配置。"
echo ""
