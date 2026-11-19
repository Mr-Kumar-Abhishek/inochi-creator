/*
    Copyright © 2020-2023, Inochi2D Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module creator.widgets.inputtext;
import creator.widgets;
import creator.core;
import core.stdc.string : memcpy;

private {
    struct TextCallbackUserData {
        char[]* scratch;
    }

    extern(C) int incInputTextResizeCallback(ImGuiInputTextCallbackData* data) {
        try {
            if (data !is null && data.EventFlag == ImGuiInputTextFlags.CallbackResize) {
                auto udata = cast(TextCallbackUserData*)data.UserData;
                if (udata is null || udata.scratch is null) return 0;

                int textLen = data.BufTextLen < 0 ? 0 : data.BufTextLen;
                size_t needed = cast(size_t)textLen + 1;
                if (data.BufSize > 0 && cast(size_t)data.BufSize > needed) {
                    needed = cast(size_t)data.BufSize;
                }

                if ((*udata.scratch).length < needed) {
                    (*udata.scratch).length = needed;
                }

                data.Buf = (*udata.scratch).ptr;
                data.BufSize = cast(int)((*udata.scratch).length > int.max ? int.max : (*udata.scratch).length);
                data.Buf[textLen] = '\0';
            }
        } catch (Throwable) {
            // Never unwind D exceptions across C/C++ ImGui callbacks.
        }
        return 0;
    }

    bool incInputTextImpl(string wId, float width, ref string buffer, ImGuiInputTextFlags flags) {
        static char[] scratch;

        if (wId.ptr is null) wId = "";
        if (buffer.ptr is null) buffer = "";

        size_t initialLen = buffer.length;
        foreach (i, char c; buffer) {
            if (c == '\0') {
                initialLen = i;
                break;
            }
        }

        if (scratch.length < initialLen + 1) {
            scratch.length = initialLen + 1;
        }
        if (initialLen > 0) {
            memcpy(scratch.ptr, buffer.ptr, initialLen);
        }
        scratch[initialLen] = '\0';

        // Push ID
        auto id = igGetID(wId.ptr, wId.ptr + wId.length);
        igPushID(id);
        scope(exit) igPopID();

        // Set desired width
        igPushItemWidth(width);
        scope(exit) igPopItemWidth();

        TextCallbackUserData cb;
        cb.scratch = &scratch;

        bool result = igInputText(
            "###INPUT",
            scratch.ptr,
            scratch.length,
            flags | ImGuiInputTextFlags.CallbackResize,
            &incInputTextResizeCallback,
            &cb
        );

        size_t actualLen = 0;
        while (actualLen < scratch.length && scratch[actualLen] != '\0') {
            actualLen++;
        }

        if (scratch[0 .. actualLen] != buffer) {
            buffer = scratch[0 .. actualLen].idup;
        }

        return result;
    }
}

/**
    D compatible text input
*/
bool incInputText(string wId, ref string buffer, ImGuiInputTextFlags flags = ImGuiInputTextFlags.None) {
    auto available = incAvailableSpace();
    return incInputText(wId, available.x, buffer, flags);
}

/**
    D compatible text input
*/
bool incInputText(string wId, float width, ref string buffer, ImGuiInputTextFlags flags = ImGuiInputTextFlags.None) {
    return incInputTextImpl(wId, width, buffer, flags);
}

/**
    D compatible text input
*/
bool incInputText(string wId, string label, ref string buffer, ImGuiInputTextFlags flags = ImGuiInputTextFlags.None) {
    auto available = incAvailableSpace();
    return incInputText(wId, label, available.x, buffer, flags);
}

/**
    D compatible text input
*/
bool incInputText(string wId, string label, float width, ref string buffer, ImGuiInputTextFlags flags = ImGuiInputTextFlags.None) {
    if (label.ptr is null) label = "";

    bool result = incInputTextImpl(wId, width, buffer, flags);
    igSameLine(0, igGetStyle().ItemSpacing.x);
    igTextEx(label.ptr, label.ptr + label.length);
    return result;
}

unittest {
    char[] buf = ['a', 'b', '\0'];
    TextCallbackUserData cb;
    cb.scratch = &buf;

    // Grows buffer for multi-byte CJK UTF-8 input
    string cjk = "日本語テスト";
    ImGuiInputTextCallbackData data;
    data.EventFlag = ImGuiInputTextFlags.CallbackResize;
    data.UserData = &cb;
    data.Buf = buf.ptr;
    data.BufTextLen = cast(int)cjk.length;
    data.BufSize = cast(int)cjk.length + 1;

    assert(incInputTextResizeCallback(&data) == 0);
    assert(buf.length >= cjk.length + 1);
    assert(data.Buf is buf.ptr);
    assert(data.BufSize == cast(int)buf.length);
    assert(data.Buf[cjk.length] == '\0');

    // Clamps negative BufTextLen safely to 0
    data.BufTextLen = -5;
    data.BufSize = 4;
    assert(incInputTextResizeCallback(&data) == 0);
    assert(data.Buf[0] == '\0');
}
