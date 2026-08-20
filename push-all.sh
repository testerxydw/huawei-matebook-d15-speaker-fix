#!/bin/bash
# 同时推送当前分支到 gitee 和 github
# 用法: ./push-all.sh [分支名]   (默认: 当前所在分支)
set -u

BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
[ -z "$BRANCH" ] && { echo "错误: 无法确定分支" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "错误: 不在 git 仓库内" >&2; exit 1
}
cd "$REPO_ROOT" || exit 1

echo "==> 推送分支 '$BRANCH' 到所有远程"

status=0
for remote in gitee origin; do
    echo
    echo "---- [$remote] ----"
    if git push "$remote" "$BRANCH" 2>&1; then
        echo "[$remote] 成功"
    else
        echo "[$remote] 失败" >&2
        status=1
    fi
done

echo
if [ "$status" = "0" ]; then
    echo "==> 全部推送完成"
else
    echo "==> 存在失败,请检查上面的输出" >&2
fi
exit "$status"
