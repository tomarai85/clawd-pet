# Third-party notices

## Orca (look of the chat terminal)

The chat panel's terminal colours and panel chrome follow the floating terminal of Orca (https://github.com/stablyai/orca), which is MIT licensed:

> Copyright (c) 2026 Lovecast Inc.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
> to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
> and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
> IN THE SOFTWARE.

What follows Orca: the terminal colours of its dark theme ("Ayu Dark") and light theme, the 10 px panel corner radius, the 1 px panel border (white or
black at 14 %), the 36 px title bar and the colour tokens of its fill, border and button. Only values (numbers and hex colours) are used; no Orca
source file is copied. Ayu Dark is a public theme (https://github.com/ayu-theme); Orca's light ANSI colours are those of the public GitHub Light theme.

Round 2 adds the panel's behaviour numbers, again as values only: the 420 x 280 minimum size, the 8 px screen margin and 12 px maximize margin
(floating-terminal-panel-bounds.ts), the eight resize handles, 8 px thick, inset 8 px from the corners, with 12 px corner squares
(FloatingTerminalResizeHandles.tsx), the title bar drag and double-click maximize (floating-terminal-panel-drag-actions.ts), and the tab's 6 % fill,
180 px width and 2 px bottom line (tab-bar/drop-indicator.ts, tab-width-rules.ts).

## The chat page (Stage 2: Orca's Native Chat look in a web view)

The chat page (`chat-page/`, installed to `~/Library/Application Support/clawd-pet/chat-page/`) widens the Orca MIT notice above from values to the chat
page's look and markup: the colour tokens, radii, spacing, type sizes and element structure of Orca's Native Chat (`src/renderer/src/components/native-chat/`,
`assets/main.css`, `components/sidebar/comment-markdown-element-renderers.tsx`, at commit a7c8c3baefd), resolved from Tailwind classes to plain CSS in
`page.css`; each rule names the Orca file and line it follows. The same notice (Copyright (c) 2026 Lovecast Inc., MIT) applies to it.

Files shipped in the page directory, each with its licence beside it:
- Geist (Vercel's typeface, the file Orca bundles as `Geist-Variable.woff2`): SIL Open Font License 1.1, Copyright 2024 The Geist Project Authors
  (https://github.com/vercel/geist-font); the licence text is `OFL.txt`.
- marked 12.0.2 (`marked.min.js`, https://github.com/markedjs/marked): MIT, Copyright (c) 2018+ MarkedJS and (c) 2011-2018 Christopher Jeffrey;
  the licence text is `LICENSE-marked.txt`.
- Lucide 0.577.0 icons (the eye, square-terminal, pencil, search, globe, bot, wrench and loader-circle paths inlined in `page.js`): ISC, with the
  Feather MIT notice for the portions derived from it; the licence text is `LICENSE-lucide.txt`.
