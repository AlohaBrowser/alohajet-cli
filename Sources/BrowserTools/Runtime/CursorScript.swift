import Foundation

// MARK: - Cursor color helpers

/// Converts an HSL triple (hue 0-360, saturation/lightness as percentages) to a
/// `#rrggbb` hex color.
nonisolated func hslToHex(_ hue: Double, _ saturation: Double, _ lightness: Double) -> String {
    let s = saturation / 100
    let l = lightness / 100
    let chroma = (1 - abs(2 * l - 1)) * s
    let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = l - chroma / 2
    let (r, g, b): (Double, Double, Double) = switch hue {
    case 0..<60: (chroma, x, 0)
    case 60..<120: (x, chroma, 0)
    case 120..<180: (0, chroma, x)
    case 180..<240: (0, x, chroma)
    case 240..<300: (x, 0, chroma)
    case 300..<360: (chroma, 0, x)
    default: (0, 0, 0)
    }
    func hex(_ component: Double) -> String {
        String(format: "%02x", max(0, min(255, Int(((component + m) * 255).rounded()))))
    }
    return "#\(hex(r))\(hex(g))\(hex(b))"
}

/// Maps an arbitrary seed string to a deterministic hex color. `variant`
/// chooses a brighter or darker lightness.
nonisolated func stringToHexColor(_ seed: String, _ variant: String = "dark") -> String {
    let normalized = (seed == "default" || seed.isEmpty ? "default" : seed)
        .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        .lowercased()
    let basis = String(String.UnicodeScalarView(normalized.unicodeScalars.prefix(6)))
    var hash = 0
    for scalar in basis.unicodeScalars {
        hash = (hash << 5) &- hash &+ Int(scalar.value)
        hash = hash & 0xFFFFFFFF
    }
    if hash > 0x7FFFFFFF { hash -= 0x100000000 }
    let hue = Double(abs(hash) % 360)
    return variant == "bright" ? hslToHex(hue, 56, 86) : hslToHex(hue, 60, 45)
}

nonisolated func stringToDarkHexColor(_ seed: String) -> String {
    stringToHexColor(seed, "dark")
}

/// How the in-page agent arrow is painted.
///
/// One colour for every agent on purpose: the arrow is a pointer, and a per-seed
/// hue made it read as decoration and lost contrast on the pages whose accent it
/// happened to match. The white stroke around it is what keeps it visible on a dark page.
public enum AgentCursorAppearance {
    public nonisolated static let fillHex = "#000000"

    /// Whether the in-page cursor flourish is painted at all.
    ///
    /// The animation is up to 600ms of pure cosmetics on EVERY click. That is
    /// worth paying while someone is watching the agent work — it is how a
    /// viewer can tell what it is about to touch — and it is pure tax on a
    /// benchmark or headless run where nobody is. One switch, off only when asked:
    ///
    ///     ALOHAJET_HIGHLIGHTS=0     # the agent behaves identically
    ///
    /// Nothing the model sees changes. The synthetic `Input.dispatchMouseEvent`
    /// is sent either way; only the paint is skipped, so a run with the flourish
    /// off is the same run.
    ///
    /// Read once: the value cannot change mid-run, and re-reading the
    /// environment would put a syscall on the click path.
    public nonisolated static let animationEnabled: Bool =
        parseHighlights(ProcessInfo.processInfo.environment["ALOHAJET_HIGHLIGHTS"])

    /// Default ON. Only an explicit off value disables it, so a missing or
    /// malformed setting keeps the affordance a watching user relies on rather
    /// than silently hiding the agent's work.
    nonisolated static func parseHighlights(_ raw: String?) -> Bool {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["0", "false", "no", "off"].contains(value)
    }
}

// MARK: - Cursor animation script

/// Builds the page-side cursor-animation script: it draws an arrow marker
/// (`#ai-mouse-marker`) where the agent's pointer was left, tweens it along a
/// randomized cubic Bézier toward the target, optionally adds a press scale
/// flourish, and then lets the marker fade away once the agent stops working.
///
/// THE START POSITION LIVES IN THE PAGE, at `window.__alohaAgentCursor`. It belongs to
/// the document, not to this process: it must survive between two actions on one page
/// and it must NOT survive a navigation, which is exactly what a page global does for
/// free. The host has no synchronous way to read it back — `getAgentMousePosition()` is
/// a nonisolated protocol read — and the alternative, a coordinate cached on the tab,
/// would go on pointing at a place on a page that is gone.
nonisolated func buildAgentCursorClickScript(
    targetX: Int,
    targetY: Int,
    color: String,
    scaleOnClick: Bool
) -> String {
    let scaleFlag = scaleOnClick ? "true" : "false"
    return #"""
      function lerp(start, end, t) {
        return start + (end - start) * t;
      }

      function bezierPoint(p0, p1, p2, p3, t) {
        const oneMinusT = 1 - t;
        return (
          oneMinusT * oneMinusT * oneMinusT * p0 +
          3 * oneMinusT * oneMinusT * t * p1 +
          3 * oneMinusT * t * t * p2 +
          t * t * t * p3
        );
      }

      // The arrow is a signal that the agent is working, so it outlives one action and
      // dies when the agent stops. The linger is longer than the gap between two actions
      // in a sequence — each one cancels this and redraws — so the cursor stays put while
      // the agent works and is gone shortly after it finishes, instead of being left
      // painted on the page until the next navigation.
      function scheduleCursorFade(marker) {
        window.__alohaAgentCursorFade = setTimeout(() => {
          window.__alohaAgentCursorFade = null;
          marker.style.transition = 'opacity 0.3s ease-out';
          marker.style.opacity = '0';
          setTimeout(() => marker.remove(), 320);
        }, 2000);
      }

      async function animateMouseMovement(targetX, targetY, scaleOnClick) {

        // Where the agent left the pointer last, on THIS document. Absent on the first
        // action, and then the marker appears at the target instead of travelling from
        // a corner it was never at.
        const remembered = window.__alohaAgentCursor;
        const startX = (remembered && typeof remembered.x === 'number') ? remembered.x : targetX;
        const startY = (remembered && typeof remembered.y === 'number') ? remembered.y : targetY;

        // A pending fade from the previous action would otherwise delete the marker this
        // one is about to draw.
        if (window.__alohaAgentCursorFade) {
          clearTimeout(window.__alohaAgentCursorFade);
          window.__alohaAgentCursorFade = null;
        }

        const existingMarker = document.getElementById('ai-mouse-marker');
        if (existingMarker) existingMarker.remove();

        const existingClickEffect = document.getElementById('ai-click-effect');
        if (existingClickEffect) existingClickEffect.remove();


        const marker = document.createElement('div');
        marker.id = 'ai-mouse-marker';
        marker.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22" style="pointer-events: none;"><path fill="\#(color)" stroke="#FFF" stroke-width="2" d="M5.5 3.21V20.8c0 .45.54.67.85.35l4.86-4.86a.5.5 0 0 1 .35-.15h6.87a.5.5 0 0 0 .35-.85L6.35 2.85a.5.5 0 0 0-.85.35Z" style="pointer-events: none;"></path></svg>';
        marker.style.cssText =
          'position: fixed;' +
          'width: 22px;' +
          'height: 22px;' +
          'pointer-events: none;' +
          'z-index: 2147483647;' +
          'filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.5));' +
          'left: ' + startX + 'px;' +
          'top: ' + startY + 'px;';
        document.body.appendChild(marker);

        marker.style.transition = 'none';

        const midX = (startX + targetX) / 2;
        const midY = (startY + targetY) / 2;
        const distance = Math.hypot(targetX - startX, targetY - startY);
        const variance = Math.min(120, Math.max(20, distance * 0.15));

        const cp1x = midX + (Math.random() - 0.5) * variance;
        const cp1y = midY + (Math.random() - 0.5) * variance;
        const cp2x = midX + (Math.random() - 0.5) * variance;
        const cp2y = midY + (Math.random() - 0.5) * variance;

        const duration = Math.min(600, Math.max(120, distance * 0.35));
        const startTime = performance.now();

        return new Promise(resolve => {
          function animate(currentTime) {
            const elapsed = currentTime - startTime;
            const progress = Math.min(elapsed / duration, 1);

            const x = bezierPoint(startX, cp1x, cp2x, targetX, progress);
            const y = bezierPoint(startY, cp1y, cp2y, targetY, progress);
            const jitter = Math.sin(progress * 10) * Math.min(0.5, distance * 0.002);

            const currentX = x + jitter;
            const currentY = y + jitter;

            marker.style.left = currentX + 'px';
            marker.style.top = currentY + 'px';

            if (progress < 1) {
              requestAnimationFrame(animate);
            } else {
              window.__alohaAgentCursor = { x: targetX, y: targetY };
              scheduleCursorFade(marker);
              if (scaleOnClick) {
                marker.style.transition = 'transform 0.15s ease-out';

                marker.style.transform = 'scale(0.9)';

                setTimeout(() => {
                  marker.style.transform = 'scale(1)';
                  setTimeout(resolve, 150);
                }, 150);
              } else {
                resolve();
              }
            }
          }

          requestAnimationFrame(animate);
        });
      }

      new Promise(async (resolve) => {
        try {
          await animateMouseMovement(\#(targetX), \#(targetY), \#(scaleFlag));
          resolve();
        } catch (error) {
          resolve();
        }
      });
    """#
}
