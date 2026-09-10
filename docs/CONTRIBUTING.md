# Contributing

Thanks for your interest in contributing to cmpunlocker! This guide covers submitting changes.

---

## Submitting Changes

1. **Open a PR** and use the required [format](https://github.com/amoghmunikote/cmpunlocker/blob/master/.github/pull_request_template.md). **If you don't use it, I will reject it.** No exceptions.
   
2. **Be patient.** Currently, I'm the only person maintaining cmpunlocker so won't be able to get to you right away.

3. **Be ready to change your code.** Chances are I will scrutinize your code heavily if I need to, so be prepared.

4. **Merge!** When all is approved, you can merge your changes. 

---

## Pull Requests I will reject:

- PRs that don't follow this template: I already said it above!
- AI slop: I don't want your straight AI slop that you cooked up in 2 minutes using Claude Code. It's going to be shitty and full of bloat. If you are inclined to do this, please review the code you are going to submit.
- Documentation: That's for me to manage, not you.
- Support for other cards: Maintaining cmpunlocker for a single card is already a lot of work for me. If you've already put the work into making a PR, I bet you can fork cmpunlocker and modify it to support your card.

## Code Style & Conventions

- **Minimize the diff**: cmpunlocker should be as light as possible in terms of size.
- **Comments**: Please add comments as little as you can.
- **Testing**: Always test on physical hardware before submitting. Describe your test environment (distro, kernel version, card variant).
