# Open-source references

The separate nonactivating preview panel, delayed hover and stale-result
cancellation in `Sources/MacToys/Dock/DockWindowPeek.swift` were informed by
[HyperDock FullSizePreview.swift](https://github.com/trunkszi/hyperdock/blob/a66e60cf9d7978c1bc948639a108c84526291bf0/Sources/HyperDock/UI/FullSizePreview.swift).
MacToys implements its own original-position placement and reuses its existing
ScreenCaptureKit capture gate. No external runtime dependency is included.

HyperDock is distributed under the MIT License:

MIT License

Copyright (c) 2026 HyperDock

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
