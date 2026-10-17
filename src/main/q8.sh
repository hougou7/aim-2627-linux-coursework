#!/bin/bash
# Q8：repair 时识别并停止采集器、修复 HTTP 服务；cleanup 时停止修复后的服务。
# 完整接口与验收规格见 Problem.pdf。只修改本文件，不修改测试或工具。
set -eu
input=${1:?需要输入目录}
output=${2:?需要输出目录}

action=${3:-repair}

source "$input/process.env"

process_running() {
    local process_state
    process_state=$(ps -p "$1" -o stat=) || return 1
    case "$process_state" in
        ""|*Z*) return 1 ;;
    esac
    return 0
}

stop_process() {
    local pid=$1 attempt
    case "$pid" in
        ""|*[!0-9]*)
            printf 'Invalid PID: %s\n' "$pid" >&2
            return 1
            ;;
    esac
    if [ "$pid" -le 1 ]; then
        printf 'Invalid PID: %s\n' "$pid" >&2
        return 1
    fi

    if process_running "$pid"; then
        kill -TERM "$pid"
    fi
    for attempt in {1..50}; do
        if ! process_running "$pid"; then
            return 0
        fi
        sleep 0.1
    done
    printf 'Timed out waiting for PID %s to stop\n' "$pid" >&2
    return 1
}

port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$TARGET_PORT") 2>/dev/null
}

case "$action" in
    repair)
        mkdir -p "$output"

        # Capture the target process before stopping it.
        read -r actual_pid owner state <<< "$(
            ps -p "$TARGET_PID" -o pid= -o user:256= -o stat=
        )"
        command_line=$(ps -ww -p "$TARGET_PID" -o args=)
        case "$command_line" in
            *"$TARGET_TOKEN"*) ;;
            *)
                printf 'Target process token does not match\n' >&2
                exit 1
                ;;
        esac
        printf '%s\n' \
            "pid=$actual_pid" \
            "user=$owner" \
            "state=$state" \
            "command=$command_line" \
            > "$output/process.txt"

        # Save only this collector's ticks, with a bounded wait for two records.
        for attempt in {1..30}; do
            awk -v token="$TARGET_TOKEN" \
                '$1 == "TICK" && $2 == token' "$WORKER_LOG" \
                > "$output/collector-sample.log"
            if [ "$(wc -l < "$output/collector-sample.log")" -ge 2 ]; then
                break
            fi
            sleep 0.1
        done
        if [ "$(wc -l < "$output/collector-sample.log")" -lt 2 ]; then
            printf 'Timed out waiting for collector logs\n' >&2
            exit 1
        fi
        stop_process "$TARGET_PID"
        stop_process "$SERVICE_PID"

        printf 'bind=127.0.0.1\nport=%s\nroute=/status\n' "$TARGET_PORT" \
            > "$output/server.conf"
        bash "$START_TOOL" "$output/server.conf" "$output/service"
        read -r repaired_pid < "$output/service/pid"

        # Keep the repaired service running after a successful HTTP check.
        ready=false
        for attempt in {1..30}; do
            if curl --noproxy '*' --silent --show-error \
                --connect-timeout 0.2 --max-time 0.2 \
                --output "$output/http-body.txt" \
                --write-out '%{http_code}\n' \
                "http://127.0.0.1:$TARGET_PORT/status" \
                > "$output/http-status.txt" 2>/dev/null \
                && [ "$(cat "$output/http-status.txt")" = "200" ] \
                && printf 'SENTRY READY\n' | cmp -s - "$output/http-body.txt"; then
                ready=true
                break
            fi
            sleep 0.1
        done
        if [ "$ready" != true ]; then
            printf 'Timed out waiting for the repaired HTTP service\n' >&2
            cat "$output/service/service.log" >&2
            stop_process "$repaired_pid"
            exit 1
        fi
        ;;
    cleanup)
        read -r repaired_pid < "$output/service/pid"
        stop_process "$repaired_pid"
        for attempt in {1..30}; do
            if ! port_open; then
                exit 0
            fi
            sleep 0.1
        done
        printf 'Port %s is still in use\n' "$TARGET_PORT" >&2
        exit 1
        ;;
    *)
        printf 'Unknown action: %s\n' "$action" >&2
        exit 1
        ;;
esac
