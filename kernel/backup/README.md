# kernel/backup — ES8316 codec 驱动版本存档

本目录保存 ES8316 codec 驱动的两种版本，供在 ostree/overlay 不可变系统上通过
fstab bind mount 部署（见 `/etc/fstab`）：

```
/persistent/snd-soc-es8316.ko.zst → /usr/lib/modules/<kver>/kernel/sound/soc/codecs/snd-soc-es8316.ko.zst
```

## 版本说明

| 文件 | srcversion | 说明 |
|------|-----------|------|
| `snd-soc-es8316.ko.zst` | `417873854FBE7975CD19D15` | **原版**（发行版自带），未改动。无 JD 电源域保持修复，运行期 jack 检测更易短暂冻结。md5=`acdf59b337ea55202d8088482945b497` |
| `snd-soc-es8316.ko.PATCH-892945FF.zst` | `892945FF6EA5C30AD111508` | **修复版**（本项目编译，**修复过**）。新增 `force_enable_pin("Bias"/"Analog power")` 保持 JD 相关电源域常开，避免 codec 深睡导致 jack 检测冻结，拔插联动更稳定。md5=`aeb50ab9f79ab75e1028050acbed2877` |

## 切换方法

想用哪个版本，就把对应文件部署为 bind mount 源（如 `/persistent/snd-soc-es8316.ko.zst`）后重启：
- 用修复版：`sudo cp snd-soc-es8316.ko.PATCH-892945FF.zst /persistent/snd-soc-es8316.ko.zst`
- 用原版：`sudo cp snd-soc-es8316.ko.zst /persistent/snd-soc-es8316.ko.zst`

源码与编译产物见 `../es8316-patch/`。
