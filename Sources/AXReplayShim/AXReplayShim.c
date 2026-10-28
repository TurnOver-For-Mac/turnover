// SPDX-License-Identifier: GPL-3.0-or-later
#include "AXReplayShim.h"
#include <stdbool.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static pid_t floorPid = 0;
static axreplay_attr_fn attrFn; static axreplay_names_fn attrNamesFn, paramNamesFn, actionNamesFn;
static axreplay_param_fn paramFn; static axreplay_action_fn actionFn; static axreplay_set_fn setFn;

void axreplay_install(pid_t floor, axreplay_attr_fn attr, axreplay_names_fn attrNames, axreplay_names_fn paramNames,
                      axreplay_names_fn actionNames, axreplay_param_fn param, axreplay_action_fn action, axreplay_set_fn set) {
    floorPid = floor; attrFn = attr; attrNamesFn = attrNames; paramNamesFn = paramNames; actionNamesFn = actionNames;
    paramFn = param; actionFn = action; setFn = set;
}

bool axreplay_handles(AXUIElementRef element) {
    if (floorPid == 0 || element == NULL) return false;
    pid_t p = 0;
    AXUIElementGetPid(element, &p);
    return p >= floorPid;
}

static AXError my_CopyAttributeValue(AXUIElementRef e, CFStringRef a, CFTypeRef *v) {
    if (axreplay_handles(e) && attrFn) return attrFn(e, a, v);
    return AXUIElementCopyAttributeValue(e, a, v);
}
static AXError my_GetAttributeValueCount(AXUIElementRef e, CFStringRef a, CFIndex *count) {
    if (axreplay_handles(e) && attrFn) {
        CFTypeRef v = NULL;
        AXError err = attrFn(e, a, &v);
        if (err != kAXErrorSuccess) { if (v) CFRelease(v); return err; }
        if (!v || CFGetTypeID(v) != CFArrayGetTypeID()) {
            if (v) CFRelease(v);
            return kAXErrorIllegalArgument;
        }
        *count = CFArrayGetCount(v);
        if (v) CFRelease(v);
        return kAXErrorSuccess;
    }
    return AXUIElementGetAttributeValueCount(e, a, count);
}
// Bounded-array reads must also hit the replay provider, rather than accidentally asking a real process (#166).
static AXError my_CopyAttributeValues(AXUIElementRef e, CFStringRef a, CFIndex index, CFIndex maxValues, CFArrayRef *values) {
    if (axreplay_handles(e) && attrFn) {
        CFTypeRef v = NULL;
        AXError err = attrFn(e, a, &v);
        if (err != kAXErrorSuccess) { if (v) CFRelease(v); return err; }
        if (!v || CFGetTypeID(v) != CFArrayGetTypeID() || index < 0 || maxValues < 0) {
            if (v) CFRelease(v);
            return kAXErrorIllegalArgument;
        }
        CFIndex count = CFArrayGetCount(v);
        if (index > count || (index == count && count > 0)) { CFRelease(v); return kAXErrorIllegalArgument; }
        CFIndex length = MIN(maxValues, count - index);
        CFMutableArrayRef out = CFArrayCreateMutable(NULL, length, &kCFTypeArrayCallBacks);
        for (CFIndex i = index; i < index + length; i++) CFArrayAppendValue(out, CFArrayGetValueAtIndex(v, i));
        CFRelease(v); *values = out;
        return kAXErrorSuccess;
    }
    return AXUIElementCopyAttributeValues(e, a, index, maxValues, values);
}
static AXError my_CopyAttributeNames(AXUIElementRef e, CFArrayRef *names) {
    if (axreplay_handles(e) && attrNamesFn) return attrNamesFn(e, names);
    return AXUIElementCopyAttributeNames(e, names);
}
static AXError my_CopyParameterizedAttributeNames(AXUIElementRef e, CFArrayRef *names) {
    if (axreplay_handles(e) && paramNamesFn) return paramNamesFn(e, names);
    return AXUIElementCopyParameterizedAttributeNames(e, names);
}
static AXError my_CopyActionNames(AXUIElementRef e, CFArrayRef *names) {
    if (axreplay_handles(e) && actionNamesFn) return actionNamesFn(e, names);
    return AXUIElementCopyActionNames(e, names);
}
static AXError my_CopyParameterizedAttributeValue(AXUIElementRef e, CFStringRef a, CFTypeRef p, CFTypeRef *v) {
    if (axreplay_handles(e) && paramFn) return paramFn(e, a, p, v);
    return AXUIElementCopyParameterizedAttributeValue(e, a, p, v);
}
static AXError my_PerformAction(AXUIElementRef e, CFStringRef action) {
    if (axreplay_handles(e) && actionFn) return actionFn(e, action);
    return AXUIElementPerformAction(e, action);
}
static AXError my_SetAttributeValue(AXUIElementRef e, CFStringRef a, CFTypeRef v) {
    if (axreplay_handles(e) && setFn) return setFn(e, a, v);
    return AXUIElementSetAttributeValue(e, a, v);
}
static AXError my_IsAttributeSettable(AXUIElementRef e, CFStringRef a, Boolean *settable) {
    if (axreplay_handles(e)) { *settable = true; return kAXErrorSuccess; }
    return AXUIElementIsAttributeSettable(e, a, settable);
}
static AXError my_CopyMultipleAttributeValues(AXUIElementRef e, CFArrayRef attributes, AXCopyMultipleAttributeOptions options, CFArrayRef *values) {
    if (axreplay_handles(e) && attrFn) {
        CFIndex n = CFArrayGetCount(attributes);
        CFMutableArrayRef out = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < n; i++) {
            CFTypeRef v = NULL;
            AXError err = attrFn(e, (CFStringRef)CFArrayGetValueAtIndex(attributes, i), &v);
            if (err != kAXErrorSuccess) {
                if (v) CFRelease(v);
                if (options & kAXCopyMultipleAttributeOptionStopOnError) { CFRelease(out); return err; }
                AXValueRef errorValue = AXValueCreate(kAXValueAXErrorType, &err);
                CFArrayAppendValue(out, errorValue); CFRelease(errorValue);
            } else if (v) { CFArrayAppendValue(out, v); CFRelease(v); }
            else CFArrayAppendValue(out, kCFNull);
        }
        *values = out;
        return kAXErrorSuccess;
    }
    return AXUIElementCopyMultipleAttributeValues(e, attributes, options, values);
}

DYLD_INTERPOSE(my_CopyAttributeValue, AXUIElementCopyAttributeValue)
DYLD_INTERPOSE(my_GetAttributeValueCount, AXUIElementGetAttributeValueCount)
DYLD_INTERPOSE(my_CopyAttributeValues, AXUIElementCopyAttributeValues)
DYLD_INTERPOSE(my_CopyAttributeNames, AXUIElementCopyAttributeNames)
DYLD_INTERPOSE(my_CopyParameterizedAttributeNames, AXUIElementCopyParameterizedAttributeNames)
DYLD_INTERPOSE(my_CopyActionNames, AXUIElementCopyActionNames)
DYLD_INTERPOSE(my_CopyParameterizedAttributeValue, AXUIElementCopyParameterizedAttributeValue)
DYLD_INTERPOSE(my_PerformAction, AXUIElementPerformAction)
DYLD_INTERPOSE(my_SetAttributeValue, AXUIElementSetAttributeValue)
DYLD_INTERPOSE(my_IsAttributeSettable, AXUIElementIsAttributeSettable)
DYLD_INTERPOSE(my_CopyMultipleAttributeValues, AXUIElementCopyMultipleAttributeValues)
