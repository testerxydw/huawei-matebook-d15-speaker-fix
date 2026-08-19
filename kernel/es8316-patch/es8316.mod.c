#include <linux/module.h>
#include <linux/export-internal.h>
#include <linux/compiler.h>

MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};



static const struct modversion_info ____versions[]
__used __section("__versions") = {
	{ 0x96bbccec, "regcache_mark_dirty" },
	{ 0x33d0c686, "clk_disable" },
	{ 0x33d0c686, "clk_unprepare" },
	{ 0x06817e8b, "devm_clk_get_optional" },
	{ 0xd8b288f3, "clk_prepare" },
	{ 0xd8b288f3, "clk_enable" },
	{ 0x00854d4f, "snd_soc_component_write" },
	{ 0x0feb1e94, "usleep_range_state" },
	{ 0xa32bac4c, "_dev_warn" },
	{ 0x823d0973, "devm_kmalloc" },
	{ 0x99e8adb3, "__devm_regmap_init_i2c" },
	{ 0xc1e6c71e, "__mutex_init" },
	{ 0xfcef23ba, "devm_snd_soc_register_component" },
	{ 0xb90cded1, "devm_request_threaded_irq" },
	{ 0xf4367c5e, "i2c_del_driver" },
	{ 0xbd03ed67, "__ref_stack_chk_guard" },
	{ 0xcd002fc9, "regmap_read" },
	{ 0x3340e573, "snd_soc_jack_report" },
	{ 0x79fbfa9e, "__dynamic_dev_dbg" },
	{ 0x6b1449ee, "snd_soc_dapm_disable_pin_unlocked" },
	{ 0xd272d446, "__stack_chk_fail" },
	{ 0x92d74e2b, "device_property_read_bool" },
	{ 0x6b1449ee, "snd_soc_dapm_force_enable_pin" },
	{ 0x61693d1b, "snd_soc_dapm_sync" },
	{ 0x8e3336dd, "enable_irq" },
	{ 0x8e3336dd, "disable_irq" },
	{ 0x172b7bf2, "snd_soc_info_enum_double" },
	{ 0xf4a97cd8, "snd_soc_dapm_get_enum_double" },
	{ 0xf4a97cd8, "snd_soc_dapm_put_enum_double" },
	{ 0x172b7bf2, "snd_soc_info_volsw" },
	{ 0xf4a97cd8, "snd_soc_dapm_get_volsw" },
	{ 0xf4a97cd8, "snd_soc_dapm_put_volsw" },
	{ 0xc998cbc6, "snd_soc_get_volsw" },
	{ 0xc998cbc6, "snd_soc_put_volsw" },
	{ 0xc998cbc6, "snd_soc_get_enum_double" },
	{ 0xc998cbc6, "snd_soc_put_enum_double" },
	{ 0xd272d446, "__fentry__" },
	{ 0xd272d446, "__x86_return_thunk" },
	{ 0x73b75189, "i2c_register_driver" },
	{ 0x1cca40e9, "snd_soc_component_update_bits" },
	{ 0xb2bd2a94, "snd_pcm_hw_constraint_list" },
	{ 0xa32bac4c, "_dev_err" },
	{ 0x71a97e4a, "clk_set_rate" },
	{ 0xf46d5bf3, "mutex_lock" },
	{ 0x6b1449ee, "snd_soc_dapm_force_enable_pin_unlocked" },
	{ 0x61693d1b, "snd_soc_dapm_sync_unlocked" },
	{ 0xf46d5bf3, "mutex_unlock" },
	{ 0x67628f51, "msleep" },
	{ 0x5dc04770, "regcache_cache_only" },
	{ 0x0c13e958, "regcache_sync" },
	{ 0xadda1318, "module_layout" },
};

static const u32 ____version_ext_crcs[]
__used __section("__version_ext_crcs") = {
	0x96bbccec,
	0x33d0c686,
	0x33d0c686,
	0x06817e8b,
	0xd8b288f3,
	0xd8b288f3,
	0x00854d4f,
	0x0feb1e94,
	0xa32bac4c,
	0x823d0973,
	0x99e8adb3,
	0xc1e6c71e,
	0xfcef23ba,
	0xb90cded1,
	0xf4367c5e,
	0xbd03ed67,
	0xcd002fc9,
	0x3340e573,
	0x79fbfa9e,
	0x6b1449ee,
	0xd272d446,
	0x92d74e2b,
	0x6b1449ee,
	0x61693d1b,
	0x8e3336dd,
	0x8e3336dd,
	0x172b7bf2,
	0xf4a97cd8,
	0xf4a97cd8,
	0x172b7bf2,
	0xf4a97cd8,
	0xf4a97cd8,
	0xc998cbc6,
	0xc998cbc6,
	0xc998cbc6,
	0xc998cbc6,
	0xd272d446,
	0xd272d446,
	0x73b75189,
	0x1cca40e9,
	0xb2bd2a94,
	0xa32bac4c,
	0x71a97e4a,
	0xf46d5bf3,
	0x6b1449ee,
	0x61693d1b,
	0xf46d5bf3,
	0x67628f51,
	0x5dc04770,
	0x0c13e958,
	0xadda1318,
};
static const char ____version_ext_names[]
__used __section("__version_ext_names") =
	"regcache_mark_dirty\0"
	"clk_disable\0"
	"clk_unprepare\0"
	"devm_clk_get_optional\0"
	"clk_prepare\0"
	"clk_enable\0"
	"snd_soc_component_write\0"
	"usleep_range_state\0"
	"_dev_warn\0"
	"devm_kmalloc\0"
	"__devm_regmap_init_i2c\0"
	"__mutex_init\0"
	"devm_snd_soc_register_component\0"
	"devm_request_threaded_irq\0"
	"i2c_del_driver\0"
	"__ref_stack_chk_guard\0"
	"regmap_read\0"
	"snd_soc_jack_report\0"
	"__dynamic_dev_dbg\0"
	"snd_soc_dapm_disable_pin_unlocked\0"
	"__stack_chk_fail\0"
	"device_property_read_bool\0"
	"snd_soc_dapm_force_enable_pin\0"
	"snd_soc_dapm_sync\0"
	"enable_irq\0"
	"disable_irq\0"
	"snd_soc_info_enum_double\0"
	"snd_soc_dapm_get_enum_double\0"
	"snd_soc_dapm_put_enum_double\0"
	"snd_soc_info_volsw\0"
	"snd_soc_dapm_get_volsw\0"
	"snd_soc_dapm_put_volsw\0"
	"snd_soc_get_volsw\0"
	"snd_soc_put_volsw\0"
	"snd_soc_get_enum_double\0"
	"snd_soc_put_enum_double\0"
	"__fentry__\0"
	"__x86_return_thunk\0"
	"i2c_register_driver\0"
	"snd_soc_component_update_bits\0"
	"snd_pcm_hw_constraint_list\0"
	"_dev_err\0"
	"clk_set_rate\0"
	"mutex_lock\0"
	"snd_soc_dapm_force_enable_pin_unlocked\0"
	"snd_soc_dapm_sync_unlocked\0"
	"mutex_unlock\0"
	"msleep\0"
	"regcache_cache_only\0"
	"regcache_sync\0"
	"module_layout\0"
;

MODULE_INFO(depends, "snd-soc-core,snd-pcm");

MODULE_ALIAS("acpi*:ESSX8316:*");
MODULE_ALIAS("acpi*:ESSX8336:*");
MODULE_ALIAS("of:N*T*Ceverest,es8316");
MODULE_ALIAS("of:N*T*Ceverest,es8316C*");
MODULE_ALIAS("i2c:es8316");

MODULE_INFO(srcversion, "B6B2D5A35A698D1FA41E5AF");
