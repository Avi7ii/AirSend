package com.airsend.xposed

import android.content.Intent
import android.util.Log
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam
import java.util.ArrayList

/**
 * Adds AirSend to ColorOS 16's Content Portal as the first fixed destination.
 *
 * Content Portal does not enumerate Android share targets. Its fixed destinations are built by
 * an internal rule factory, so the normal ACTION_SEND manifest filter is insufficient here.
 */
class ContentPortalHook : IXposedHookLoadPackage {

    override fun handleLoadPackage(lpparam: LoadPackageParam) {
        if (lpparam.packageName != CONTENT_PORTAL_PACKAGE) return

        try {
            XposedHelpers.findAndHookMethod(
                FIXED_RULE_FACTORY_CLASS,
                lpparam.classLoader,
                FIXED_RULE_FACTORY_METHOD,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        injectAirSendRule(param.result, lpparam.classLoader)
                    }
                }
            )
            log("ColorOS Content Portal hook installed")
        } catch (error: Throwable) {
            log("Unsupported Content Portal build; fixed target hook not installed", error)
        }
    }

    private fun injectAirSendRule(response: Any?, classLoader: ClassLoader) {
        if (response == null) return

        try {
            val data = XposedHelpers.callMethod(response, "getData") ?: return
            val existingRules = XposedHelpers.callMethod(data, "getDataList") as? List<*> ?: return
            if (existingRules.any(::isAirSendRule)) return

            val rules = ArrayList<Any>(existingRules.size + 1)
            rules.add(createAirSendRule(classLoader))
            existingRules.filterNotNullTo(rules)
            XposedHelpers.callMethod(data, "setDataList", rules)
            log("AirSend injected as the first fixed Content Portal target")
        } catch (error: Throwable) {
            log("Failed to inject AirSend into Content Portal", error)
        }
    }

    private fun isAirSendRule(rule: Any?): Boolean {
        if (rule == null) return false
        return runCatching {
            (XposedHelpers.callMethod(rule, "getId") as? Number)?.toInt() == AIRSEND_SERVICE_ID
        }.getOrDefault(false)
    }

    private fun createAirSendRule(classLoader: ClassLoader): Any {
        val rule = newInstance(DRAG_RULE_CLASS, classLoader)
        set(rule, "setFinalId", AIRSEND_FINAL_ID)
        set(rule, "setId", AIRSEND_SERVICE_ID)
        set(rule, "setServiceName", AIRSEND_LABEL)
        set(rule, "setServiceNameTranslated", AIRSEND_LABEL)
        set(rule, "setManyApp", false)
        set(rule, "setBasicContentList", arrayListOf(createBasicContent(classLoader)))
        set(rule, "setServiceConditionBean", createServiceCondition(classLoader))
        set(rule, "setOnlineStatus", "上线")
        return rule
    }

    private fun createBasicContent(classLoader: ClassLoader): Any {
        val app = newInstance(APP_AND_PACKAGE_CLASS, classLoader)
        set(app, "setAppName", AIRSEND_LABEL)
        set(app, "setPackageName", AIRSEND_PACKAGE)

        val jump = newInstance(BASIC_JUMP_CLASS, classLoader)
        set(jump, "setData1", "action")
        set(jump, "setData2", "activity")
        set(jump, "setJumpUrl", Intent.ACTION_SEND)

        val content = newInstance(BASIC_CONTENT_CLASS, classLoader)
        set(content, "setBasicSupportServiceAppAndPackageNameBean", app)
        set(content, "setBasicJumpBean", jump)
        set(content, "setBasicMap", hashMapOf("class" to AIRSEND_SHARE_ACTIVITY))
        set(content, "setBasicExt", "")
        return content
    }

    private fun createServiceCondition(classLoader: ClassLoader): Any {
        val identify = newInstance(SERVICE_IDENTIFY_CLASS, classLoader)
        set(identify, "setServiceConditionServiceIdentifyType", "")
        set(identify, "setServiceConditionServiceIdentifyValue", "")

        val condition = newInstance(SERVICE_CONDITION_CLASS, classLoader)
        set(condition, "setServiceConditionServiceType", "固定推荐服务")
        set(condition, "setServiceConditionServiceIdentifyBeanList", arrayListOf(identify))
        set(condition, "setServiceConditionServiceIdentifyExt", "")
        set(condition, "setServiceConditionDragType", SUPPORTED_CONTENT_TYPES)
        set(condition, "setServiceConditionDragNumber", "不涉及")
        set(condition, "setServiceConditionExt", "")
        return condition
    }

    private fun newInstance(className: String, classLoader: ClassLoader): Any =
        XposedHelpers.newInstance(XposedHelpers.findClass(className, classLoader))

    private fun set(target: Any, methodName: String, value: Any) {
        XposedHelpers.callMethod(target, methodName, value)
    }

    private fun log(message: String, error: Throwable? = null) {
        Log.i(TAG, message, error)
        if (error == null) {
            XposedBridge.log("$TAG: $message")
        } else {
            XposedBridge.log("$TAG: $message\n${Log.getStackTraceString(error)}")
        }
    }

    private companion object {
        const val TAG = "AirSendContentPortal"
        const val CONTENT_PORTAL_PACKAGE = "com.oplus.contentportal"
        const val AIRSEND_PACKAGE = "com.airsend"
        const val AIRSEND_SHARE_ACTIVITY = "com.airsend.ShareTargetActivity"
        const val AIRSEND_LABEL = "AirSend"
        const val AIRSEND_SERVICE_ID = 29_001
        const val AIRSEND_FINAL_ID = 29_001L
        const val SUPPORTED_CONTENT_TYPES = "图片,文本,音频,视频,文档,压缩包,安装包"

        // Verified against com.oplus.contentportal 16.8.7 (ColorOS 16).
        const val FIXED_RULE_FACTORY_CLASS = "e6.h"
        const val FIXED_RULE_FACTORY_METHOD = "a"
        const val DRAG_RULE_CLASS =
            "com.oplus.contentportal.permanent.repository.database.DragAndDropRule"
        const val BASIC_CONTENT_CLASS =
            "com.oplus.contentportal.permanent.repository.database.BasicContentBean"
        const val BASIC_JUMP_CLASS =
            "com.oplus.contentportal.permanent.repository.database.BasicJumpBean"
        const val APP_AND_PACKAGE_CLASS =
            "com.oplus.contentportal.permanent.repository.database.BasicSupportServiceAppAndPackageNameBean"
        const val SERVICE_CONDITION_CLASS =
            "com.oplus.contentportal.permanent.repository.database.ServiceConditionBean"
        const val SERVICE_IDENTIFY_CLASS =
            "com.oplus.contentportal.permanent.repository.database.ServiceConditionServiceIdentifyBean"
    }
}
