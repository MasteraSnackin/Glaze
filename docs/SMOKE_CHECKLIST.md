# Smoke Test Checklist

Manual verification checklist for each refactor PR.
Run on each target platform before merging.

---

## Platform Matrix

| Test | Web (Chrome) | Android (Capacitor) | iOS (Capacitor) |
|------|:---:|:---:|:---:|
| All tests below | ☐ | ☐ | ☐ |

---

## Chat Generation

- [ ] Send a message → model responds with streaming text
- [ ] Send a message with `stream: false` → model responds in one block
- [ ] Press stop during streaming → partial text is preserved
- [ ] Press stop during streaming (no text yet) → message is removed / restored
- [ ] Press regenerate during active generation → no second generation starts
- [ ] Press regenerate on a completed message → new response generates
- [ ] Impersonation works: press impersonate → character message appears
- [ ] Swipe between responses works after generation
- [ ] Switch to another character during generation → generation continues in background
- [ ] Switch back to the generating character → isGenerating state is correct

## Summary

- [ ] Generate summary → returns a text summary
- [ ] Summary does not affect isGenerating or chat state
- [ ] Summary can be regenerated

## Memory Draft

- [ ] Trigger memory draft generation → progress indicator shows
- [ ] Memory draft completes → draft text appears
- [ ] Memory draft cannot start while chat generation is active → toast shown
- [ ] Memory draft can be cancelled

## Prompt Construction

- [ ] Preset blocks appear in correct order in prompt preview
- [ ] Lorebook keyword entries are injected
- [ ] Lorebook vector entries are injected (when searchType allows)
- [ ] Memory book entries are injected
- [ ] Author's note appears at the configured depth
- [ ] Session variable macros resolve correctly
- [ ] Custom macros resolve correctly
- [ ] Regex scripts are applied to block content
- [ ] Context overflow → error message shown, generation aborted
- [ ] Context cutoff trims oldest messages, not newest

## Error Handling

- [ ] API not configured → bottom sheet shown
- [ ] Invalid API key → error message shown in chat
- [ ] Network timeout → error handled gracefully
- [ ] Context limit exceeded → notification shown
- [ ] Model not found → error shown

## State Consistency

- [ ] After error, isGenerating is false
- [ ] After abort, isGenerating is false
- [ ] After completion, isGenerating is false
- [ ] No stuck isGenerating after rapid abort/regenerate cycles
- [ ] No stuck isGenerating after switching characters during generation
- [ ] Navigating away and back → generation state is correct

## Platform-Specific

### Web
- [ ] SSE streaming works over HTTPS
- [ ] Non-streaming fetch works

### Android
- [ ] Native HTTP requests work for local API URLs
- [ ] Background generation continues when app is minimized
- [ ] Wake lock prevents sleep during generation
- [ ] Android notification shows during background generation

### iOS
- [ ] Background generation continues when app is minimized
- [ ] Memory limit factor (15x) is used for history retention
