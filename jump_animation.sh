#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 清屏函数
clear_screen() {
    if command -v clear >/dev/null; then
        clear
    elif command -v cls >/dev/null; then
        cls
    else
        echo -e "\033c"
    fi
}

# 延迟函数
sleep_ms() {
    if command -v sleep >/dev/null && sleep --help 2>&1 | grep -q "--ms"; then
        sleep --ms "$1"
    elif command -v usleep >/dev/null; then
        usleep "$(( $1 * 1000 ))"
    else
        # 回退方案，精度较低
        local seconds=$(echo "scale=3; $1 / 1000" | bc)
        sleep "$seconds"
    fi
}

# 显示标题
show_title() {
    clear_screen
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}         明日方舟：终末地              ${NC}"
    echo -e "${CYAN}           跳跃机制模拟器              ${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "${YELLOW}这不是官方工具！纯粉丝恶搞项目${NC}"
    echo
}

# 双跳动画
double_jump_animation() {
    show_title
    echo -e "${GREEN}双跳动画演示${NC}"
    echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
    echo
    
    local frame=0
    local max_frames=10
    
    while true; do
        clear_screen
        show_title
        echo -e "${GREEN}双跳动画演示${NC}"
        echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
        echo
        
        case $frame in
            0)
                echo "       ___"
                echo "      /   \
                /     \
               /       \
              /         \
             /           \
            /             \
           /               \
          /_________________\"
                ;;
            1)
                echo "         ___"
                echo "        /   \
               /     \
              /       \
             /         \
            /           \
           /             \
          /               \
         /_________________\"
                ;;
            2)
                echo "           ___"
                echo "          /   \
                 /     \
                /       \
               /         \
              /           \
             /             \
            /               \
           /_________________\"
                ;;
            3)
                echo "         ___"
                echo "        /   \
               /     \
              /       \
             /         \
            /           \
           /             \
          /               \
         /_________________\"
                ;;
            4)
                echo "       ___"
                echo "      /   \
                /     \
               /       \
              /         \
             /           \
            /             \
           /               \
          /_________________\"
                ;;
            5)
                echo "        ___"
                echo "       /   \
              /     \
             /       \
            /         \
           /           \
          /             \
         /               \
        /_________________\"
                ;;
            6)
                echo "       ___"
                echo "      /   \
                /     \
               /       \
              /         \
             /           \
            /             \
           /               \
          /_________________\"
                ;;
            7)
                echo "        ___"
                echo "       /   \
              /     \
             /       \
            /         \
           /           \
          /             \
         /               \
        /_________________\"
                ;;
            8)
                echo "       ___"
                echo "      /   \
                /     \
               /       \
              /         \
             /           \
            /             \
           /               \
          /_________________\"
                ;;
            9)
                echo "        ___"
                echo "       /   \
              /     \
             /       \
            /         \
           /           \
          /             \
         /               \
        /_________________\"
                ;;
        esac
        
        frame=$(( (frame + 1) % max_frames ))
        sleep_ms 100
    done
}

# 跑酷动画
parkour_animation() {
    show_title
    echo -e "${GREEN}跑酷动画演示${NC}"
    echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
    echo
    
    local frame=0
    local max_frames=8
    
    while true; do
        clear_screen
        show_title
        echo -e "${GREEN}跑酷动画演示${NC}"
        echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
        echo
        
        case $frame in
            0)
                echo "  ____________________"
                echo " /                    \"
                echo "/                      \"
                echo "|                      |"
                echo "|         O            |"
                echo "|        /|\\          |"
                echo "|        / \\          |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|______________________|"
                ;;
            1)
                echo "  ____________________"
                echo " /                    \"
                echo "/                      \"
                echo "|                      |"
                echo "|          O           |"
                echo "|         /|\\          |"
                echo "|         / \\          |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|______________________|"
                ;;
            2)
                echo "  ____________________"
                echo " /                    \"
                echo "/                      \"
                echo "|                      |"
                echo "|            O         |"
                echo "|           /|\\          |"
                echo "|           / \\          |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|______________________|"
                ;;
            3)
                echo "  ____________________"
                echo " /                    \"
                echo "/                      \"
                echo "|                      |"
                echo "|             O        |"
                echo "|            /|\\       |"
                echo "|            / \\       |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|______________________|"
                ;;
            4)
                echo "  ____________________"
                echo " /                    \"
                echo "/                      \"
                echo "|                      |"
                echo "|              O       |"
                echo "|             /|\\      |"
                echo "|             / \\      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|______________________|"
                ;;
            5)
                echo "  ____________________"
                echo " /                    \"
                echo "/                      \"
                echo "|                      |"
                echo "|               O      |"
                echo "|              /|\\     |"
                echo "|              / \\     |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|______________________|"
                ;;
            6)
                echo "  ____________________"
                echo " /                    \"
                echo "/                      \"
                echo "|                      |"
                echo "|                O     |"
                echo "|               /|\\    |"
                echo "|               / \\    |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|______________________|"
                ;;
            7)
                echo "  ____________________"
                echo " /                    \"
                echo "/                      \"
                echo "|                      |"
                echo "|                 O    |"
                echo "|                /|\\   |"
                echo "|                / \\   |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|                      |"
                echo "|______________________|"
                ;;
        esac
        
        frame=$(( (frame + 1) % max_frames ))
        sleep_ms 150
    done
}

# Ardelia卡墙动画
ardelia_wall_animation() {
    show_title
    echo -e "${GREEN}Ardelia卡墙动画演示${NC}"
    echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
    echo
    
    local frame=0
    local max_frames=6
    
    while true; do
        clear_screen
        show_title
        echo -e "${GREEN}Ardelia卡墙动画演示${NC}"
        echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
        echo
        
        case $frame in
            0)
                echo "  _______"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       | O"
                echo " |       |/|\\"
                echo " |       |/ \\"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |_______|"
                ;;
            1)
                echo "  _______"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       | O"
                echo " |       |/|\\"
                echo " |       |/ \\"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |_______|"
                ;;
            2)
                echo "  _______"
                echo " |       |"
                echo " |       |"
                echo " |       | O"
                echo " |       |/|\\"
                echo " |       |/ \\"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |_______|"
                ;;
            3)
                echo "  _______"
                echo " |       |"
                echo " |       | O"
                echo " |       |/|\\"
                echo " |       |/ \\"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |_______|"
                ;;
            4)
                echo "  _______"
                echo " |       | O"
                echo " |       |/|\\"
                echo " |       |/ \\"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |_______|"
                ;;
            5)
                echo "  _______ O"
                echo " |       |/|\\"
                echo " |       |/ \\"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |       |"
                echo " |_______|"
                ;;
        esac
        
        frame=$(( (frame + 1) % max_frames ))
        sleep_ms 200
    done
}

# Meme实验
meme_experiment() {
    show_title
    echo -e "${GREEN}Meme实验${NC}"
    echo
    
    local memes=(
        "${YELLOW}当你学会双跳后：${NC}\n${GREEN}我要跳到月球上去！${NC}"
        "${YELLOW}当你尝试Ardelia卡墙：${NC}\n${RED}卡住了...怎么办？${NC}"
        "${YELLOW}跑酷时的你：${NC}\n${GREEN}我感觉自己像个超级英雄！${NC}"
        "${YELLOW}当你从高处落下：${NC}\n${RED}啊啊啊啊啊啊啊！${NC}"
        "${YELLOW}官方看到这个工具：${NC}\n${BLUE}这是什么鬼？${NC}"
    )
    
    for meme in "${memes[@]}"; do
        echo -e "$meme"
        echo
        sleep 2
    done
    
    echo -e "${CYAN}Meme实验结束！${NC}"
    sleep 1
}

# 主菜单
main_menu() {
    while true; do
        show_title
        echo "请选择要查看的动画："
        echo "1) 双跳动画"
        echo "2) 跑酷动画"
        echo "3) Ardelia卡墙动画"
        echo "4) Meme实验"
        echo "5) 退出"
        echo
        read -p "请输入选项 [1-5]: " choice
        
        case $choice in
            1)
                double_jump_animation
                ;;
            2)
                parkour_animation
                ;;
            3)
                ardelia_wall_animation
                ;;
            4)
                meme_experiment
                ;;
            5)
                echo -e "${CYAN}感谢使用跳跃机制模拟器！${NC}"
                echo -e "${YELLOW}玩得开心～ 🪂${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入。${NC}"
                sleep 1
                ;;
        esac
    done
}

# 检查脚本是否以bash运行
if [ "$0" = "$BASH_SOURCE" ]; then
    main_menu
else
    echo "请使用bash运行此脚本：bash jump_animation.sh"
fi
