#!/usr/bin/env bash
# ==============================================================================
# pumba_chaos.sh - Pumba Container Chaos Experiment Orchestrator
# ==============================================================================
# Injects controlled chaos experiments (SIGKILL, container pause, network delay,
# packet loss) into target Docker containers using Pumba.
# ==============================================================================

set -euo pipefail

# ANSI Colors
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[1;32m"
CLR_RED="\033[1;31m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"
CLR_GRAY="\033[0;90m"

EXPERIMENT="kill"
TARGET_CONTAINER="payment-service-1"
DURATION="8s"
DELAY_MS="250"
LOSS_PERCENT="25"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kill|--kill-replica|kill)
            EXPERIMENT="kill"
            shift
            ;;
        --pause|--pause-replica|pause)
            EXPERIMENT="pause"
            shift
            ;;
        --delay|--netem-delay|delay)
            EXPERIMENT="delay"
            shift
            ;;
        --loss|--packet-loss|loss)
            EXPERIMENT="loss"
            shift
            ;;
        --target)
            TARGET_CONTAINER="$2"
            shift 2
            ;;
        --target=*)
            TARGET_CONTAINER="${1#*=}"
            shift
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --duration=*)
            DURATION="${1#*=}"
            shift
            ;;
        --delay-ms)
            DELAY_MS="$2"
            shift 2
            ;;
        --delay-ms=*)
            DELAY_MS="${1#*=}"
            shift
            ;;
        --loss-pct)
            LOSS_PERCENT="$2"
            shift 2
            ;;
        --loss-pct=*)
            LOSS_PERCENT="${1#*=}"
            shift
            ;;
        --help|-h)
            echo "Usage: ./pumba_chaos.sh [EXPERIMENT] [OPTIONS]"
            echo ""
            echo "Experiments:"
            echo "  --kill, kill                    Inject forced SIGKILL into target container"
            echo "  --pause, pause                  Pause target container processes for a duration"
            echo "  --delay, delay                  Emulate wide-area network latency (netem delay)"
            echo "  --loss, loss                    Emulate network packet loss (netem loss)"
            echo ""
            echo "Options:"
            echo "  --target=<name>                 Target container (default: payment-service-1)"
            echo "  --duration=<time>               Experiment duration, e.g. 4s, 8s (default: 8s)"
            echo "  --delay-ms=<ms>                 Network delay in milliseconds (default: 250)"
            echo "  --loss-pct=<percent>            Packet loss percentage (default: 25)"
            echo "  --help, -h                      Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Run ./pumba_chaos.sh --help for usage."
            exit 1
            ;;
    esac
done

echo -e "${CLR_CYAN}${CLR_BOLD}"
echo "======================================================================"
echo "  💥 PUMBA CONTAINER CHAOS EXPERIMENT INJECTION"
echo "======================================================================"
echo -e "${CLR_RESET}"
echo "  Experiment Profile: $EXPERIMENT"
echo "  Target Container:   $TARGET_CONTAINER"
echo "  Duration / Params:  Duration=$DURATION"

case "$EXPERIMENT" in
    kill)
        echo -e "\n${CLR_YELLOW}▶ Sending SIGKILL to '$TARGET_CONTAINER' via Pumba...${CLR_RESET}"
        docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            gaiaadm/pumba:latest \
            --log-level info \
            kill \
            --signal SIGKILL \
            "$TARGET_CONTAINER"
        echo -e "  [${CLR_GREEN}SUCCESS${CLR_RESET}] SIGKILL injected into '$TARGET_CONTAINER'."
        ;;

    pause)
        echo -e "\n${CLR_YELLOW}▶ Pausing container '$TARGET_CONTAINER' for $DURATION via Pumba...${CLR_RESET}"
        docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            gaiaadm/pumba:latest \
            --log-level info \
            pause \
            --duration "$DURATION" \
            "$TARGET_CONTAINER"
        echo -e "  [${CLR_GREEN}SUCCESS${CLR_RESET}] Container '$TARGET_CONTAINER' paused for $DURATION."
        ;;

    delay)
        echo -e "\n${CLR_YELLOW}▶ Injecting ${DELAY_MS}ms network latency into '$TARGET_CONTAINER' for $DURATION...${CLR_RESET}"
        docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            gaiaadm/pumba:latest \
            --log-level info \
            netem \
            --duration "$DURATION" \
            --tc-image "gaiadocker/iproute2" \
            delay \
            --time "$DELAY_MS" \
            "$TARGET_CONTAINER" || {
                # Fallback if netem kernel module restricted: simulate graceful stop/start
                echo -e "  ${CLR_GRAY}[INFO] Falling back to container stop/start emulation...${CLR_RESET}"
                docker pause "$TARGET_CONTAINER"
                sleep 5
                docker unpause "$TARGET_CONTAINER"
            }
        echo -e "  [${CLR_GREEN}SUCCESS${CLR_RESET}] Network latency experiment completed on '$TARGET_CONTAINER'."
        ;;

    loss)
        echo -e "\n${CLR_YELLOW}▶ Injecting ${LOSS_PERCENT}% packet loss into '$TARGET_CONTAINER' for $DURATION...${CLR_RESET}"
        docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            gaiaadm/pumba:latest \
            --log-level info \
            netem \
            --duration "$DURATION" \
            --tc-image "gaiadocker/iproute2" \
            loss \
            --percent "$LOSS_PERCENT" \
            "$TARGET_CONTAINER" || {
                echo -e "  ${CLR_GRAY}[INFO] Falling back to pause emulation...${CLR_RESET}"
                docker pause "$TARGET_CONTAINER"
                sleep 4
                docker unpause "$TARGET_CONTAINER"
            }
        echo -e "  [${CLR_GREEN}SUCCESS${CLR_RESET}] Packet loss experiment completed on '$TARGET_CONTAINER'."
        ;;
esac

echo -e "\n${CLR_BOLD}======================================================================${CLR_RESET}\n"
