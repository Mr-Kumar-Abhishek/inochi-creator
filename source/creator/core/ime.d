/*
    Copyright © 2020-2024, Inochi2D Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module creator.core.ime;
import creator.core.dpi;
import bindbc.imgui;
import bindbc.sdl;
import std.string : fromStringz;

private {
    // SDL 2.0.22+ extended composition events (not in bindbc-sdl SDL_2020 bindings)
    enum uint SDL_EVENT_TEXTEDITING_EXT = 0x305;
    enum const(char)* SDL_HINT_IME_SUPPORT_EXTENDED_TEXT_NAME = "SDL_IME_SUPPORT_EXTENDED_TEXT";

    struct SDL_TextEditingExtEventCompat {
        uint type;
        uint timestamp;
        uint windowID;
        char* text;
        int start;
        int length;
    }
    static assert(SDL_TextEditingExtEventCompat.sizeof <= SDL_Event.sizeof);

    struct ImeState {
        bool wantVisible = false;
        ImVec2 inputPos = ImVec2(0, 0);
        float inputLineHeight = 0.0f;
        ImVec2 viewportPos = ImVec2(0, 0);
        ImGuiID viewportId = 0;

        string compositionText;
        int compositionStart = 0;
        int compositionLength = 0;

        bool isComposing() const nothrow @nogc pure {
            return compositionText.length > 0;
        }

        void clearComposition() nothrow @nogc {
            compositionText = null;
            compositionStart = 0;
            compositionLength = 0;
        }
    }

    ImeState imeState;

    void incImeUpdateTextInputRect() {
        SDL_Rect rect = incImeComputeTextInputRect(
            imeState.inputPos,
            imeState.viewportPos,
            imeState.inputLineHeight,
            incGetUIScale()
        );
        SDL_SetTextInputRect(&rect);
    }

    extern(C) void incImeSetPlatformData(ImGuiViewport* viewport, ImGuiPlatformImeData* data) {
        try {
            if (viewport is null || data is null) return;

            if (data.WantVisible) {
                imeState.wantVisible = true;
                imeState.inputPos = data.InputPos;
                imeState.inputLineHeight = data.InputLineHeight;
                imeState.viewportPos = viewport.Pos;
                imeState.viewportId = viewport.ID;

                // Start text input before setting the cursor rect so SDL backends
                // (macOS fieldEdit, Windows HIMC) allocate/enable IME context first.
                if (!SDL_IsTextInputActive()) {
                    SDL_StartTextInput();
                }
                incImeUpdateTextInputRect();
            } else {
                imeState.wantVisible = false;
                imeState.clearComposition();

                if (SDL_IsTextInputActive()) {
                    SDL_StopTextInput();
                }
            }
        } catch (Throwable) {
            // Never let a D exception unwind across C++ ImGui frames.
        }
    }
}

/**
    Computes the SDL text input rectangle in window pixel coordinates from ImGui IME data.
*/
SDL_Rect incImeComputeTextInputRect(ImVec2 inputPos, ImVec2 viewportPos, float inputLineHeight, float uiScale) nothrow @nogc pure {
    if (uiScale <= 0.0f) uiScale = 1.0f;

    int rx = cast(int)((inputPos.x - viewportPos.x) * uiScale);
    int ry = cast(int)((inputPos.y - viewportPos.y) * uiScale);
    int rh = cast(int)(inputLineHeight * uiScale);

    if (rx < 0) rx = 0;
    if (ry < 0) ry = 0;
    if (rh < 1) rh = 1;

    return SDL_Rect(rx, ry, 1, rh);
}

/**
    Converts a UTF-8 codepoint index into a clamped byte offset within `utf8`.
*/
size_t incImeCodepointToByteOffset(string utf8, int codepointIndex) nothrow @nogc pure {
    if (codepointIndex <= 0 || utf8.length == 0) return 0;

    size_t bytePos = 0;
    int cp = 0;
    while (bytePos < utf8.length && cp < codepointIndex) {
        ubyte b = cast(ubyte)utf8[bytePos];
        size_t seqLen = 1;
        if ((b & 0x80) == 0) seqLen = 1;
        else if ((b & 0xE0) == 0xC0) seqLen = 2;
        else if ((b & 0xF0) == 0xE0) seqLen = 3;
        else if ((b & 0xF8) == 0xF0) seqLen = 4;

        if (bytePos + seqLen > utf8.length) {
            seqLen = utf8.length - bytePos;
        }
        bytePos += seqLen;
        cp++;
    }
    return bytePos;
}

/**
    Returns true if `sym` is a modifier or lock key that should not be suppressed during IME composition.
*/
bool incImeIsModifierKey(SDL_Keycode sym) nothrow @nogc pure {
    switch (sym) {
        case SDLK_LCTRL:
        case SDLK_RCTRL:
        case SDLK_LSHIFT:
        case SDLK_RSHIFT:
        case SDLK_LALT:
        case SDLK_RALT:
        case SDLK_LGUI:
        case SDLK_RGUI:
        case SDLK_CAPSLOCK:
        case SDLK_MODE:
            return true;
        default:
            return false;
    }
}

/**
    Configures SDL2 IME hints prior to SDL_Init/window creation.
*/
void incImeSetHints() {
    SDL_SetHint(SDL_HINT_IME_SHOW_UI, "1");
    SDL_SetHint(SDL_HINT_IME_SUPPORT_EXTENDED_TEXT_NAME, "1");
}

/**
    Initializes ImGui -> SDL2 IME bridge after ImGui context and SDL2 backend init.
*/
void incImeInit() {
    imeState = ImeState.init;
    igGetIO().SetPlatformImeDataFn = &incImeSetPlatformData;

    // Keep text input disabled until an editable ImGui widget requests IME focus.
    if (SDL_IsTextInputActive()) {
        SDL_StopTextInput();
    }
}

/**
    Shuts down IME state and detaches the ImGui platform IME callback.
*/
void incImeShutdown() {
    imeState = ImeState.init;
    if (igGetCurrentContext() !is null) {
        igGetIO().SetPlatformImeDataFn = null;
    }
}

/**
    Returns whether an IME pre-edit composition is currently active.
*/
bool incImeIsComposing() nothrow @nogc {
    return imeState.wantVisible && imeState.isComposing();
}

/**
    Processes SDL IME composition, text input, focus, and keydown events.
    Returns true if the event was consumed and should not be forwarded to ImGui.
*/
bool incImeProcessEvent(const(SDL_Event)* event) {
    if (event is null) return false;

    if (cast(uint)event.type == SDL_EVENT_TEXTEDITING_EXT) {
        auto ext = cast(const(SDL_TextEditingExtEventCompat)*)event;
        if (ext.text !is null) {
            imeState.compositionText = fromStringz(ext.text).idup;
            imeState.compositionStart = ext.start;
            imeState.compositionLength = ext.length;
            SDL_free(cast(void*)ext.text);
        } else {
            imeState.clearComposition();
        }
        return true;
    }

    switch (event.type) {
        case SDL_TEXTEDITING:
            size_t len = 0;
            while (len < SDL_TEXTEDITINGEVENT_TEXT_SIZE && event.edit.text[len] != '\0') {
                len++;
            }
            imeState.compositionText = len > 0 ? event.edit.text[0 .. len].idup : null;
            imeState.compositionStart = event.edit.start;
            imeState.compositionLength = event.edit.length;
            return true;

        case SDL_TEXTINPUT:
            imeState.clearComposition();
            return false;

        case SDL_KEYDOWN:
            // Suppress non-modifier keydowns while IME composition is active
            // (notably on macOS where SDL_KEYDOWN precedes interpretKeyEvents).
            if (incImeIsComposing() && !incImeIsModifierKey(event.key.keysym.sym)) {
                return true;
            }
            return false;

        case SDL_WINDOWEVENT:
            if (event.window.event == SDL_WINDOWEVENT_FOCUS_LOST) {
                imeState.clearComposition();
            } else if (event.window.event == SDL_WINDOWEVENT_FOCUS_GAINED) {
                if (imeState.wantVisible) {
                    if (!SDL_IsTextInputActive()) {
                        SDL_StartTextInput();
                    }
                    incImeUpdateTextInputRect();
                }
            }
            return false;

        default:
            return false;
    }
}

/**
    Renders the active IME pre-edit composition string overlay on the foreground draw list.
*/
void incImeRenderComposition() {
    if (!imeState.wantVisible || imeState.compositionText.length == 0) return;

    ImGuiViewport* vp = imeState.viewportId != 0 ? igFindViewportByID(imeState.viewportId) : null;
    if (vp is null) vp = igGetMainViewport();
    if (vp is null) return;

    ImDrawList* drawList = igGetForegroundDrawList(vp);
    if (drawList is null) return;

    string text = imeState.compositionText;
    float lineHeight = imeState.inputLineHeight > 0.0f ? imeState.inputLineHeight : igGetFontSize();

    ImVec2 textSize;
    igCalcTextSize(&textSize, text.ptr, text.ptr + text.length, false, -1.0f);
    if (textSize.y < lineHeight) textSize.y = lineHeight;

    enum float padX = 3.0f;
    enum float padY = 2.0f;

    ImVec2 pos = imeState.inputPos;
    float minX = vp.Pos.x + padX;
    float maxX = vp.Pos.x + vp.Size.x - textSize.x - padX;
    if (pos.x > maxX) pos.x = maxX;
    if (pos.x < minX) pos.x = minX;

    float minY = vp.Pos.y + padY;
    float maxY = vp.Pos.y + vp.Size.y - textSize.y - padY;
    if (pos.y > maxY) pos.y = maxY;
    if (pos.y < minY) pos.y = minY;

    ImVec2 boxMin = ImVec2(pos.x - padX, pos.y - padY);
    ImVec2 boxMax = ImVec2(pos.x + textSize.x + padX, pos.y + textSize.y + padY);

    ImDrawList_AddRectFilled(drawList, boxMin, boxMax, igGetColorU32(ImGuiCol.PopupBg), 2.0f);
    ImDrawList_AddRect(drawList, boxMin, boxMax, igGetColorU32(ImGuiCol.Border), 2.0f);

    size_t selStartByte = incImeCodepointToByteOffset(text, imeState.compositionStart);
    size_t selEndByte = imeState.compositionLength > 0
        ? incImeCodepointToByteOffset(text, imeState.compositionStart + imeState.compositionLength)
        : selStartByte;

    float preW = 0.0f;
    if (selStartByte > 0) {
        ImVec2 preSize;
        igCalcTextSize(&preSize, text.ptr, text.ptr + selStartByte, false, -1.0f);
        preW = preSize.x;
    }

    float selW = 0.0f;
    if (selEndByte > selStartByte) {
        ImVec2 selSize;
        igCalcTextSize(&selSize, text.ptr + selStartByte, text.ptr + selEndByte, false, -1.0f);
        selW = selSize.x;
        if (selW > 0.0f) {
            ImDrawList_AddRectFilled(
                drawList,
                ImVec2(pos.x + preW, pos.y),
                ImVec2(pos.x + preW + selW, pos.y + textSize.y),
                igGetColorU32(ImGuiCol.TextSelectedBg)
            );
        }
    }

    ImU32 textCol = igGetColorU32(ImGuiCol.Text);
    ImDrawList_AddText(drawList, pos, textCol, text.ptr, text.ptr + text.length);

    float underlineY = pos.y + textSize.y;
    ImDrawList_AddLine(
        drawList,
        ImVec2(pos.x, underlineY),
        ImVec2(pos.x + textSize.x, underlineY),
        igGetColorU32(ImGuiCol.Text, 0.5f),
        1.0f
    );

    if (selW > 0.0f) {
        ImDrawList_AddLine(
            drawList,
            ImVec2(pos.x + preW, underlineY),
            ImVec2(pos.x + preW + selW, underlineY),
            textCol,
            2.0f
        );
    } else if (imeState.compositionStart >= 0) {
        ImDrawList_AddLine(
            drawList,
            ImVec2(pos.x + preW, pos.y + 1.0f),
            ImVec2(pos.x + preW, pos.y + textSize.y - 1.0f),
            textCol,
            1.0f
        );
    }
}

unittest {
    // incImeComputeTextInputRect tests
    {
        auto r1 = incImeComputeTextInputRect(ImVec2(120.5f, 80.5f), ImVec2(0.0f, 0.0f), 13.0f, 1.0f);
        assert(r1 == SDL_Rect(120, 80, 1, 13));

        auto r2 = incImeComputeTextInputRect(ImVec2(120.0f, 80.0f), ImVec2(20.0f, 10.0f), 14.0f, 1.5f);
        assert(r2 == SDL_Rect(150, 105, 1, 21));

        auto r3 = incImeComputeTextInputRect(ImVec2(50.0f, 40.0f), ImVec2(10.0f, 10.0f), 16.0f, 2.0f);
        assert(r3 == SDL_Rect(80, 60, 1, 32));

        // Clamps negative coords, zero line height, and non-positive uiScale
        auto r4 = incImeComputeTextInputRect(ImVec2(-5.0f, -10.0f), ImVec2(10.0f, 20.0f), 0.0f, 0.0f);
        assert(r4 == SDL_Rect(0, 0, 1, 1));
    }

    // incImeCodepointToByteOffset tests
    {
        assert(incImeCodepointToByteOffset("", 0) == 0);
        assert(incImeCodepointToByteOffset("", 5) == 0);
        assert(incImeCodepointToByteOffset("abc", -1) == 0);
        assert(incImeCodepointToByteOffset("abc", 0) == 0);
        assert(incImeCodepointToByteOffset("abc", 2) == 2);
        assert(incImeCodepointToByteOffset("abc", 10) == 3);

        // 2-byte Cyrillic: "Привет" (6 chars * 2 bytes = 12 bytes)
        string ru = "Привет";
        assert(incImeCodepointToByteOffset(ru, 3) == 6);

        // 3-byte Japanese/Chinese/Korean: "日本語" (9 bytes), "中文" (6 bytes), "한국어" (9 bytes)
        string ja = "日本語";
        assert(incImeCodepointToByteOffset(ja, 1) == 3);
        assert(incImeCodepointToByteOffset(ja, 2) == 6);
        assert(incImeCodepointToByteOffset(ja, 3) == 9);
        assert(incImeCodepointToByteOffset("中文", 1) == 3);
        assert(incImeCodepointToByteOffset("한국어", 2) == 6);

        // 4-byte emoji + mixed ASCII/CJK: "a😀日b" (1 + 4 + 3 + 1 = 9 bytes)
        string mixed = "a😀日b";
        assert(incImeCodepointToByteOffset(mixed, 1) == 1);
        assert(incImeCodepointToByteOffset(mixed, 2) == 5);
        assert(incImeCodepointToByteOffset(mixed, 3) == 8);
        assert(incImeCodepointToByteOffset(mixed, 4) == 9);

        // Truncated UTF-8 trailing sequence never reads out of bounds
        immutable char[2] truncBuf = [cast(char)0xE6, cast(char)0x97];
        assert(incImeCodepointToByteOffset(truncBuf[], 1) == 2);
    }

    // incImeProcessEvent state machine tests
    {
        scope(exit) imeState = ImeState.init;
        imeState = ImeState.init;
        imeState.wantVisible = true;

        assert(!incImeIsComposing());

        SDL_Event ev;
        ev.type = SDL_TEXTEDITING;
        string comp = "にほん";
        ev.edit.text[0 .. comp.length] = comp[];
        ev.edit.text[comp.length] = '\0';
        ev.edit.start = 1;
        ev.edit.length = 2;

        assert(incImeProcessEvent(&ev));
        assert(incImeIsComposing());
        assert(imeState.compositionText == "にほん");
        assert(imeState.compositionStart == 1);
        assert(imeState.compositionLength == 2);

        // Non-modifier keydowns are suppressed during composition
        SDL_Event keyDown;
        keyDown.type = SDL_KEYDOWN;
        keyDown.key.keysym.sym = SDLK_RETURN;
        assert(incImeProcessEvent(&keyDown));

        // Modifier keydowns pass through
        keyDown.key.keysym.sym = SDLK_LSHIFT;
        assert(!incImeProcessEvent(&keyDown));

        // Keyups pass through
        SDL_Event keyUp;
        keyUp.type = SDL_KEYUP;
        keyUp.key.keysym.sym = SDLK_RETURN;
        assert(!incImeProcessEvent(&keyUp));

        // SDL_TEXTINPUT clears composition and passes through to ImGui
        SDL_Event textIn;
        textIn.type = SDL_TEXTINPUT;
        textIn.text.text[0] = 'a';
        textIn.text.text[1] = '\0';
        assert(!incImeProcessEvent(&textIn));
        assert(!incImeIsComposing());

        // Suppressed keydown is NOT suppressed once composition ends
        keyDown.key.keysym.sym = SDLK_RETURN;
        assert(!incImeProcessEvent(&keyDown));

        // Empty SDL_TEXTEDITING clears composition
        assert(incImeProcessEvent(&ev));
        assert(incImeIsComposing());
        ev.edit.text[0] = '\0';
        assert(incImeProcessEvent(&ev));
        assert(!incImeIsComposing());

        // Focus lost clears composition and passes through
        ev.edit.text[0 .. comp.length] = comp[];
        ev.edit.text[comp.length] = '\0';
        assert(incImeProcessEvent(&ev));
        assert(incImeIsComposing());

        SDL_Event winEv;
        winEv.type = SDL_WINDOWEVENT;
        winEv.window.event = SDL_WINDOWEVENT_FOCUS_LOST;
        assert(!incImeProcessEvent(&winEv));
        assert(!incImeIsComposing());

        // Keydowns are never suppressed when no text widget wants IME focus
        assert(incImeProcessEvent(&ev));
        assert(incImeIsComposing());
        imeState.wantVisible = false;
        assert(!incImeIsComposing());
        assert(!incImeProcessEvent(&keyDown));
    }
}
