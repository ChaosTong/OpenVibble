// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import BridgeRuntime

struct LiveActivityStatusFormatterTests {
    @Test func promptPutsTitleInBody() {
        let raw = "15:45:20 UserPromptSubmit [Birkin] Web 测试对话"
        let lines = LiveActivityStatusFormatter.format(raw: raw)
        #expect(lines?.primary == "15:45:20 UserPromptSubmit [Birkin]")
        #expect(lines?.secondary == "Web 测试对话")
        #expect(lines?.tool == nil)
    }

    @Test func splitsTitleAndToolAtMiddleDot() {
        let raw = "15:31:23 PreToolUse [Birkin] 这套服务同时能接入esp32硬件产品对吧 · read /Users/slaver/Developer/OpenVibble/README.md"
        let lines = LiveActivityStatusFormatter.format(raw: raw)
        #expect(lines?.primary == "15:31:23 PreToolUse [Birkin]")
        #expect(lines?.secondary == "这套服务同时能接入esp32硬件产品对吧")
        #expect(lines?.tool == "read /Users/slaver/Developer/OpenVibble/README.md")
    }

    @Test func truncatesLongBody() {
        let title = String(repeating: "长", count: 90)
        let raw = "10:42 Stop [Birkin] \(title)"
        let lines = LiveActivityStatusFormatter.format(raw: raw)
        #expect(lines?.primary == "10:42 Stop [Birkin]")
        #expect(lines?.secondary?.hasSuffix("…") == true)
        #expect((lines?.secondary?.count ?? 0) <= LiveActivityStatusFormatter.bodyMaxLength)
    }

    @Test func truncatesLongToolLine() {
        let path = String(repeating: "a", count: 80)
        let raw = "10:42 PreToolUse [Birkin] title · \(path)"
        let lines = LiveActivityStatusFormatter.format(raw: raw)
        #expect(lines?.tool?.hasSuffix("…") == true)
        #expect((lines?.tool?.count ?? 0) <= LiveActivityStatusFormatter.toolMaxLength)
    }

    @Test func detailWithoutDotGoesToBody() {
        let raw = "10:42 PreToolUse [Birkin] read README.md"
        let lines = LiveActivityStatusFormatter.format(raw: raw)
        #expect(lines?.primary == "10:42 PreToolUse [Birkin]")
        #expect(lines?.secondary == "read README.md")
        #expect(lines?.tool == nil)
    }
}
