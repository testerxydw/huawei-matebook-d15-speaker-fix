华为 MateBook 扬声器/耳机切换修复脚本（纯用户空间 · 免编译内核）

适用场景：搭载 HWSP0001 功放的华为 MateBook（如 D15 BoF-XX / BOD-WXX9），在 Linux 下出现“扬声器无声”或“耳机插拔切换异常”。

📌 核心结论

如果你的机器符合条件，本脚本可以 一键修复 以下问题，且不涉及内核编译，随时可回退：

•   ✅ 扬声器完全无声

•   ✅ 插耳机后扬声器仍在响

•   ✅ 开机插着耳机，扬声器乱响

•   ✅ 拔掉耳机后扬声器没声

项目地址：
•   本仓库（优化版）：https://gitee.com/xiyidaiwa/huawei-matebook-d15-speaker-fix

•   原始项目：https://github.com/MaximushkaBed/huawei-matebook-d15-speaker-fix

🚀 快速开始（10秒确认 + 1分钟安装）

1. 确认机型是否适用

在终端执行以下命令，有输出即适用：
ls /sys/bus/i2c/devices/ | grep -i HWSP
# 预期输出示例：i2c-HWSP0001:00


若无输出，说明你的功放不是 HWSP0001，请勿直接使用（参考文末“通用性说明”）。

2. 安装与启动

git clone https://gitee.com/xiyidaiwa/huawei-matebook-d15-speaker-fix
cd huawei-matebook-d15-speaker-fix
sudo ./install.sh
sudo systemctl restart huawei-speaker-mute.service


3. 验证修复效果

完成安装后，依次检查以下场景：

场景 预期效果

插入耳机 扬声器静音，耳机有声

拔出耳机 扬声器恢复发声

开机（插耳机） 扬声器静音

开机（不插耳机） 扬声器有声

插拔瞬间 无爆音

🔍 问题根源分析

HWSP0001 功放在 Linux 下缺失官方驱动，导致两个层面的问题：

问题一：扬声器基础静音（上游已解决）

•   现象：开机后扬声器毫无反应。

•   原因：BIOS 初始化后，功放回归默认静音态，Linux 内核无驱动接管。

•   方案：通过 GPIO 上电 + I2C 回放初始化寄存器（reinit_amp）。

问题二：耳机切换逻辑断裂（本仓库解决）

•   现象：插拔耳机时，扬声器与耳机状态混乱。

•   原因：系统无法通过 GPIO 控制功放静音。必须写入功放内部的软静音寄存器（0x01=0x00），而非简单的物理引脚控制。

•   方案：监听 ALSA 插拔事件，动态写入寄存器切换状态。

✨ 方案亮点

•   纯用户空间：仅依赖 i2cset 和 alsactl，无需编译内核或加载第三方模块。

•   智能探测：自动识别 I2C 总线、ALSA 控制项（Headphone Jack）及 GPIO 线号，开箱即用。

•   精准控制：仅静音 HWSP0001 功放，不影响 ES8336 管理的耳机通路。

•   防爆音设计：拔插瞬间先将 ALSA 音量归零，待功放稳定后再恢复，杜绝“啪”声。

•   高可移植：逻辑与硬件参数分离，方便适配其他类似功放。

🛠️ 手动排查与维护

查看服务状态

systemctl status huawei-speaker-mute.service


查看功放寄存器状态（调试用）

./huawei-speaker-mute.sh status
# 0x00: 静音（耳机插入）
# 0x69: 恢复（耳机拔出）


实时监控插拔事件

alsactl monitor hw:0
# 插拔耳机时，观察 Headphone Jack 状态变化


卸载/停用

sudo systemctl stop huawei-speaker-mute.service
sudo systemctl disable huawei-speaker-mute.service


📖 通用性说明（重要）

本脚本并非万能驱动，它是针对 HWSP0001 特性的专用解决方案。

1.  完全适用：已验证的 HWSP0001 机型（如 BoF-XX, BOD-WXX9），直接安装即可。
2.  可借鉴框架：如果你的机器是其他功放芯片（非 HWSP0001），但符合以下条件，可复用本脚本框架：
    ◦   功放支持 I2C 访问且有软静音寄存器。

    ◦   耳机与扬声器为独立音频路径。

    ◦   系统存在可监听的插拔事件（ALSA Jack 或 GPIO）。

    ◦   操作：需自行使用 i2cdetect/i2cdump 确定 I2C 地址和寄存器值，替换脚本中的 set_amp() 和 reinit_amp() 函数即可。

📄 技术细节

•   内核无关性：经校验，修复过程完全运行于用户空间，与 /boot/config-$(uname -r) 内核配置无关，适用于各类未修改的 Linux 发行版。

•   依赖组件：i2c-tools, alsa-utils, systemd.

🙏 致谢

本项目基于 https://github.com/MaximushkaBed/huawei-matebook-d15-speaker-fix 进行二次开发与优化。感谢原作者解决了 HWSP0001 的基础发声问题，本仓库在此基础上重点完善了耳机插拔联动逻辑、自动探测机制及防爆音处理。

如有同机型或类似问题，欢迎提交 Issue，请务必附带 huawei-speaker-mute.sh status 及 alsactl monitor hw:0 的输出日志。

这个格式更清晰易读。需要我再帮你写一个一键部署脚本，或者梳理一份常见故障排查表（比如插耳机有爆音怎么办）吗？
