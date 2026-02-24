#!/system/bin/sh
# AirSend Daemon 启动引擎

MODDIR=${0%/*}
DAEMON_BIN="/system/bin/airsend_daemon"
LOG_PATH="/data/local/tmp/airsend_daemon.log"

# 等待系统数据分区挂载完成（最多 60 秒）
for i in $(seq 1 30); do
  [ -d "/data/local/tmp" ] && break
  sleep 2
done

# 防重复启动判断
if pgrep -f "$DAEMON_BIN" > /dev/null; then
    echo "$(date): AirSend daemon is already running, skipping..." >> "$LOG_PATH"
    exit 0
fi

# 启动守护进程
echo "$(date): Starting AirSend daemon..." >> "$LOG_PATH"
# 重定向标准输出和错误流到日志文件
nohup "$DAEMON_BIN" >> "$LOG_PATH" 2>&1 &

echo "$(date): AirSend daemon started in background." >> "$LOG_PATH"
