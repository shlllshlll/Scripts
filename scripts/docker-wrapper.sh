#!/bin/bash

function docker() {
    # 1. 获取当前 context 名称
    # 使用 command 关键字调用原生 docker，避免递归死循环
    # tr -d '[:space:]' 用于去除末尾可能存在的换行符
    local current_context
    current_context=$(command docker context show 2>/dev/null | tr -d '[:space:]')

    # 2. 判断是否是你那个旧版服务器的 context
    if [[ "$current_context" =~ ^(chatbot|chatbot2)$ ]]; then
        # 3. 如果是：带上环境变量运行原生 docker
        # 这里的变量赋值只对这一行命令生效，不会污染当前 Shell
        DOCKER_API_VERSION=1.41 command docker "$@"
    else
        # 4. 如果不是：直接透传参数运行原生 docker
        command docker "$@"
    fi
}

