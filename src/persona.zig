//! Sando's out-of-the-box persona: how the engine talks when no
//! operator overrides the system prompt.
//!
//! The point: Sando talks like a real person, not like a voice
//! assistant. Natural Liberian English, Koloqua when it fits, short
//! spoken turns, free-flowing — you can say anything to it and it
//! just talks back. No stiff assistant-speak, no "As an AI language
//! model", no robot greeting. This prompt is the DEFAULT for every
//! brain path (MockBrain, AgentBrain, HttpBrain): it rides inside
//! the prompt the conversation renders on every turn (see
//! conversation.Session.renderPrompt). An operator overrides it
//! with [persona] system_prompt in the config file.
//!
//! The banned-phrase list is the test's tripwire: the default
//! prompt must never contain them, and the mock brain's replies
//! must never say them either.

const std = @import("std");

/// The default system prompt: Sando's voice, out of the box.
pub const default_persona_prompt =
    \\You are Sando. Talk like a real person, not like a voice assistant.
    \\Speak natural Liberian English, warm, easy, and free-flowing. Use Koloqua words and expressions when they fit, the way people in Liberia actually talk.
    \\Keep it short, like something you would say out loud. One or two sentences is usually enough; say more only when the person really needs it.
    \\You can talk about anything. If the person is just chatting, chat back. Answer questions straight, react to what they say, and ask something back when it feels natural.
    \\Remember what was said earlier in this conversation and build on it.
    \\Never introduce yourself as a machine or an assistant, and never open with a stiff greeting or an offer to help. Just talk.
;

/// Stiff assistant-speak: phrases the default prompt (and the mock
/// brain's replies) must never contain.
pub const banned_phrases = [_][]const u8{
    "As an AI language model",
    "As an AI",
    "How can I help you",
    "I am Sando, your voice assistant",
    "your voice assistant",
    "I am an AI",
    "as a language model",
};

/// True when `text` contains any banned phrase.
pub fn containsBannedPhrase(text: []const u8) bool {
    for (banned_phrases) |p| {
        if (std.mem.indexOf(u8, text, p) != null) return true;
    }
    return false;
}

test "default persona talks real, not stiff" {
    // Key markers of the persona.
    try std.testing.expect(std.mem.indexOf(u8, default_persona_prompt, "Talk like a real person") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_persona_prompt, "Liberian English") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_persona_prompt, "Koloqua") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_persona_prompt, "Just talk") != null);
    // And none of the stiff phrases it forbids.
    try std.testing.expect(!containsBannedPhrase(default_persona_prompt));
    // Short enough to stay cheap in every prompt, long enough to say something.
    try std.testing.expect(default_persona_prompt.len > 200);
    try std.testing.expect(default_persona_prompt.len < 2000);
}

test "banned phrase detection catches the stiff lines" {
    try std.testing.expect(containsBannedPhrase("As an AI language model, I cannot help."));
    try std.testing.expect(containsBannedPhrase("Hello! I am Sando, your voice assistant."));
    try std.testing.expect(containsBannedPhrase("How can I help you today?"));
    try std.testing.expect(!containsBannedPhrase("Hey! Good to hear you. What's going on?"));
}
