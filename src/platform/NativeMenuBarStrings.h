#pragma once

#include <QCoreApplication>

/**
 * @brief 原生菜单文案清单，仅用于让 lupdate 提取翻译。
 *
 * NativeMenuBar 用 QCoreApplication::translate("NativeMenu", ...) 取文案，
 * lupdate 无法从 .mm 里提取这种调用，因此在这里用 QT_TRANSLATE_NOOP 登记一遍。
 * 运行时不会用到这个数组。
 */
[[maybe_unused]] static const char *const kNativeMenuSources[] = {
    QT_TRANSLATE_NOOP("NativeMenu", "文件"),
    QT_TRANSLATE_NOOP("NativeMenu", "打开文件…"),
    QT_TRANSLATE_NOOP("NativeMenu", "打开链接…"),
    QT_TRANSLATE_NOOP("NativeMenu", "打开流媒体…"),
    QT_TRANSLATE_NOOP("NativeMenu", "设置…"),
    QT_TRANSLATE_NOOP("NativeMenu", "退出"),
    QT_TRANSLATE_NOOP("NativeMenu", "帮助"),
    QT_TRANSLATE_NOOP("NativeMenu", "简播 帮助"),
    QT_TRANSLATE_NOOP("NativeMenu", "关于简播"),
};
