import Foundation
import JavaScriptCore
import Testing

/// The page that frames the read view. Its two decisions are plain functions of
/// a string, so they run here in JavaScriptCore with no browser.
@Suite("FigmaWrapperPage")
struct FigmaWrapperPageTests {

    private let context: JSContext = {
        let context = JSContext()!
        context.evaluateScript(FigmaWrapperPage.addressScript)
        return context
    }()

    private func framable(_ raw: String?) -> String? {
        let result = context.objectForKeyedSubscript("cmuxFramableAddress")
            .call(withArguments: [raw as Any? ?? NSNull()])
        guard let result, !result.isNull, !result.isUndefined else { return nil }
        return result.toString()
    }

    private func themed(_ address: String, dark: Bool) -> String? {
        context.objectForKeyedSubscript("cmuxThemedAddress")
            .call(withArguments: [address, dark])?.toString()
    }

    // MARK: - What the page frames

    @Test("it frames Figma's read-view address")
    func framesTheReadView() {
        for raw in [
            "https://embed.figma.com/design/KEY/slug?embed-host=cmux&node-id=12-2",
            "https://embed.figma.com/design/KEY/slug",
            "HTTPS://EMBED.FIGMA.COM/design/KEY/slug?node-id=12-2"
        ] {
            #expect(framable(raw) == raw, "\(raw)")
        }
    }

    @Test("a `#` straight after the host is still Figma's host, so it is framed")
    func framesAHashAfterTheHost() {
        for raw in ["https://embed.figma.com#node", "https://embed.figma.com/#node"] {
            #expect(framable(raw) == raw, "\(raw)")
        }
    }

    @Test("it frames nothing for any other address")
    func framesNothingElse() {
        for raw in [
            "https://example.com",
            "https://example.com/?https://embed.figma.com/design/KEY/slug",
            "javascript:void(0)",
            "data:text/html,<p>hi</p>",
            "http://embed.figma.com/design/KEY/slug",
            "https://embed.figma.com.example.com/design/x",
            "https://embed.figma.com@example.com/design/x",
            "https://embed.figma.com\\@example.com/design/x",
            "https://www.figma.com/design/KEY/slug",
            "file:///etc/hosts",
            ""
        ] {
            #expect(framable(raw) == nil, "\(raw)")
        }
        #expect(framable(nil) == nil)
    }

    // MARK: - Light or dark

    @Test("it sets the theme on the framed address from the pane's own scheme")
    func setsTheTheme() {
        let base = "https://embed.figma.com/design/KEY/slug?embed-host=cmux&node-id=12-2"
        let dark = themed(base, dark: true) ?? ""
        let light = themed(base, dark: false) ?? ""
        #expect(dark.contains("theme=dark"))
        #expect(light.contains("theme=light"))
        #expect(dark.hasPrefix("https://embed.figma.com/design/KEY/slug?"))
        #expect(dark.contains("node-id=12-2") && dark.contains("embed-host=cmux"))
    }

    @Test("a fragment is dropped and theme lands in the query")
    func dropsAFragment() throws {
        for base in [
            "https://embed.figma.com/design/KEY/slug?node-id=12-2#frag",
            "https://embed.figma.com/design/KEY/slug#frag"
        ] {
            let result = try #require(themed(base, dark: true), "\(base)")
            let parts = try #require(URLComponents(string: result), "\(result)")
            #expect(!result.contains("#"), "\(result)")
            #expect(parts.fragment == nil, "\(result)")
            #expect(parts.queryItems?.contains(URLQueryItem(name: "theme", value: "dark")) == true, "\(result)")
        }
    }

    @Test("an address restored with an old theme takes the pane's scheme, once")
    func replacesAnOldTheme() {
        let restored = "https://embed.figma.com/design/KEY/slug?theme=dark&node-id=12-2"
        let light = themed(restored, dark: false) ?? ""
        #expect(light.contains("theme=light"))
        #expect(!light.contains("theme=dark"))
        #expect(light.components(separatedBy: "theme=").count == 2)
    }

    /// Runs the page's own loader in JavaScriptCore with just enough browser to
    /// load it, and returns the address it put on the frame, or nil if it framed nothing.
    private func framedAddress(embed: String, darkPane: Bool) throws -> String? {
        // Both scripts come out of the page itself, so a page that lost the
        // address functions cannot pass on the strength of this file's copy.
        let scripts = FigmaWrapperPage.html.components(separatedBy: "<script>")
        let functions = try #require(scripts.dropFirst().first?.components(separatedBy: "</script>").first)
        let loader = try #require(scripts.last?.components(separatedBy: "</script>").first)
        let context = try #require(JSContext())
        context.setObject(embed, forKeyedSubscript: "EMBED" as NSString)
        context.setObject(darkPane, forKeyedSubscript: "DARK" as NSString)
        context.evaluateScript(functions)
        context.evaluateScript("""
        location = { search: '?embed=' + encodeURIComponent(EMBED) };
        URLSearchParams = function (search) {
          var map = {};
          search.replace(/^\\?/, '').split('&').forEach(function (pair) {
            var at = pair.indexOf('=');
            if (at >= 0) { map[decodeURIComponent(pair.slice(0, at))] = decodeURIComponent(pair.slice(at + 1)); }
          });
          this.get = function (name) { return name in map ? map[name] : null; };
        };
        matchMedia = function (query) {
          // Answers by the question asked: dark when the pane is dark, light otherwise.
          return { matches: query.indexOf('dark') >= 0 ? DARK : !DARK };
        };
        frames = [];
        document = {
          readyState: 'complete',
          createElement: function () {
            return { setAttribute: function () {} };
          },
          addEventListener: function () {},
          body: { appendChild: function (frame) { frames.push(frame); } }
        };
        """)
        context.evaluateScript(loader)
        let framed = context.evaluateScript("frames.length ? frames[0].src : null")
        guard let framed, !framed.isNull, !framed.isUndefined else { return nil }
        return framed.toString()
    }

    @Test("the page themes the frame from the pane's own scheme, whatever theme the address carries")
    func pageThemesFromThePane() throws {
        for dark in [true, false] {
            let opposite = dark ? "light" : "dark"
            let chosen = dark ? "dark" : "light"
            let address = "https://embed.figma.com/design/KEY/slug?node-id=12-2&theme=\(opposite)"
            let framed = try #require(try framedAddress(embed: address, darkPane: dark), "dark pane: \(dark)")
            #expect(framed.contains("theme=\(chosen)"), "dark pane \(dark): \(framed)")
            #expect(!framed.contains("theme=\(opposite)"), "dark pane \(dark): \(framed)")
        }
    }

    @Test("the page carries the two address functions the tests above run")
    func pageCarriesTheAddressFunctions() {
        #expect(FigmaWrapperPage.html.contains(FigmaWrapperPage.addressScript))
    }

    @Test("every address the CLI builds for the read view is one the page frames")
    func builtAddressesPassThePageCheck() throws {
        let wrapper = URL(fileURLWithPath: "/tmp/cmux-test/figma-embed.html")
        let links = [
            "https://www.figma.com/design/KEY/slug?node-id=12-2",
            "https://figma.com/file/KEY/slug?node-id=12:2&t=abc",
            "https://www.figma.com/board/KEY/My%20Board?node-id=1-2",
            "https://www.figma.com/slides/KEY/a+b?node-id=3-4",
            "https://www.figma.com/design/KEY/slug?node-id=12-2#frag",
            "https://www.figma.com/design/KEY/%E3%81%82?node-id=1-2",
            "HTTPS://WWW.FIGMA.COM/design/KEY/slug?node-id=1-2"
        ]
        var built: [(String, URL)] = []
        for link in links {
            let destination = try FigmaPaneURL.destination(for: try #require(URL(string: link)), wrapper: wrapper)
            guard case .embed(_, let embedded) = destination else {
                Issue.record("\(link) did not give the read view")
                continue
            }
            built.append((link, embedded))
        }
        for node in ["12-2", "12:2", "0-1", "1-2&footer=1"] {
            let link = "https://www.figma.com/design/KEY/slug"
            let destination = try FigmaPaneURL.destination(for: try #require(URL(string: link)), node: node, wrapper: wrapper)
            guard case .embed(_, let embedded) = destination else {
                Issue.record("goto \(node) did not give the read view")
                continue
            }
            built.append(("goto \(node)", embedded))
        }
        #expect(built.count == links.count + 4)
        for (source, embedded) in built {
            #expect(framable(embedded.absoluteString) == embedded.absoluteString, "\(source): \(embedded.absoluteString)")
        }
    }

    @Test("the page frames nothing for an address that is not Figma's read view")
    func pageFramesNothingElse() throws {
        for address in ["https://example.com/", "https://www.figma.com/design/KEY/slug", "javascript:alert(1)"] {
            #expect(try framedAddress(embed: address, darkPane: true) == nil, "\(address)")
        }
    }

    // MARK: - Play / prototype URL transformation

    @Test("cmuxProtoAddress transforms design embed URL to prototype embed URL with required parameters")
    func transformsDesignToProtoAddress() throws {
        let context = try #require(JSContext())
        context.evaluateScript(FigmaPlayScript.script)
        let fn = context.objectForKeyedSubscript("cmuxProtoAddress")
        let src = "https://embed.figma.com/design/KEY/slug?embed-host=cmux&footer=0&page-selector=0&node-id=12-2&theme=light"
        let result = fn?.call(withArguments: [src, "e5e5e5"])?.toString()
        let proto = try #require(result)
        let components = try #require(URLComponents(string: proto))
        #expect(components.host == "embed.figma.com")
        #expect(components.path == "/proto/KEY/slug")
        let queryMap = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(queryMap["node-id"] == "12-2")
        #expect(queryMap["starting-point-node-id"] == "12-2")
        #expect(queryMap["page-selector"] == nil)
        #expect(queryMap["hide-ui"] == "1")
        #expect(queryMap["bg-color"] == "e5e5e5")
        #expect(queryMap["scaling"] == "contain")
        #expect(queryMap["embed-host"] == "cmux")
        #expect(queryMap["footer"] == "0")
        #expect(queryMap["theme"] == "light")
    }

    @Test("cmuxProtoAddress transforms /file/ embed URL to prototype embed URL")
    func transformsFileToProtoAddress() throws {
        let context = try #require(JSContext())
        context.evaluateScript(FigmaPlayScript.script)
        let fn = context.objectForKeyedSubscript("cmuxProtoAddress")
        let src = "https://embed.figma.com/file/KEY/slug?embed-host=cmux&footer=0&page-selector=0&node-id=12-2&theme=light"
        let result = fn?.call(withArguments: [src, "e5e5e5"])?.toString()
        let proto = try #require(result)
        let components = try #require(URLComponents(string: proto))
        #expect(components.host == "embed.figma.com")
        #expect(components.path == "/proto/KEY/slug")
        let queryMap = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(queryMap["node-id"] == "12-2")
        #expect(queryMap["starting-point-node-id"] == "12-2")
        #expect(queryMap["page-selector"] == nil)
        #expect(queryMap["hide-ui"] == "1")
        #expect(queryMap["bg-color"] == "e5e5e5")
        #expect(queryMap["scaling"] == "contain")
        #expect(queryMap["embed-host"] == "cmux")
        #expect(queryMap["footer"] == "0")
        #expect(queryMap["theme"] == "light")
    }

    @Test("cmuxProtoAddress only rewrites first path segment")
    func onlyRewritesFirstPathSegment() throws {
        let context = try #require(JSContext())
        context.evaluateScript(FigmaPlayScript.script)
        let fn = context.objectForKeyedSubscript("cmuxProtoAddress")
        let src = "https://embed.figma.com/design/KEY/design-file-slug?embed-host=cmux&node-id=12-2"
        let result = fn?.call(withArguments: [src, "e5e5e5"])?.toString()
        let proto = try #require(result)
        let components = try #require(URLComponents(string: proto))
        #expect(components.path == "/proto/KEY/design-file-slug")
    }

    @Test("synthetic pageshow with persisted: true restores still read view and removes listener")
    func pageshowPersistedRestoresStill() throws {
        let context = try #require(JSContext())
        context.evaluateScript(FigmaWrapperPage.addressScript)
        let embed = "https://embed.figma.com/design/KEY/slug?embed-host=cmux&node-id=12-2"
        context.evaluateScript("""
        location = { search: '?embed=' + encodeURIComponent('\(embed)') };
        URLSearchParams = function (search) {
          var map = {};
          search.replace(/^\\?/, '').split('&').forEach(function (pair) {
            var at = pair.indexOf('=');
            if (at >= 0) { map[decodeURIComponent(pair.slice(0, at))] = decodeURIComponent(pair.slice(at + 1)); }
          });
          this.get = function (name) { return name in map ? map[name] : null; };
        };
        matchMedia = function (query) { return { matches: false }; };
        listeners = {};
        window = {
          addEventListener: function (type, fn) { listeners[type] = fn; },
          removeEventListener: function (type, fn) { if (listeners[type] === fn) { delete listeners[type]; } }
        };
        currentFrame = {
          src: 'https://embed.figma.com/design/KEY/slug?embed-host=cmux&node-id=12-2',
          setAttribute: function (k, v) { this[k] = v; },
          parentNode: {
            replaceChild: function (newChild, oldChild) {
              replaced = newChild;
              currentFrame = newChild;
            }
          }
        };
        replaced = null;
        document = {
          querySelector: function (sel) { return sel === 'iframe' ? currentFrame : null; },
          createElement: function (tag) {
            return {
              src: '',
              setAttribute: function (k, v) { this[k] = v; },
              parentNode: currentFrame.parentNode
            };
          }
        };
        """)
        let play = context.evaluateScript(FigmaPlayScript.playScript(canvasBg: "e5e5e5"))
        #expect(play?.toBool() == true)
        #expect(context.evaluateScript("currentFrame.src.indexOf('/proto/') !== -1")?.toBool() == true)
        #expect(context.evaluateScript("typeof window.__cmuxPlayRestore")?.toString() == "function")

        // Fire pageshow with persisted: false -> no restore
        context.evaluateScript("listeners['pageshow']({ persisted: false })")
        #expect(context.evaluateScript("currentFrame.src.indexOf('/proto/') !== -1")?.toBool() == true)
        #expect(context.evaluateScript("typeof window.__cmuxPlayRestore")?.toString() == "function")

        // Fire pageshow with persisted: true -> restores still and deletes __cmuxPlayRestore
        context.evaluateScript("listeners['pageshow']({ persisted: true })")
        #expect(context.evaluateScript("currentFrame.src.indexOf('/design/') !== -1")?.toBool() == true)
        #expect(context.evaluateScript("currentFrame.src.indexOf('/proto/') === -1")?.toBool() == true)
        #expect(context.evaluateScript("typeof window.__cmuxPlayRestore")?.toString() == "undefined")
        #expect(context.evaluateScript("typeof listeners['pageshow']")?.toString() == "undefined")
    }

    @Test("stillScript is idempotent: does not replace iframe when not playing")
    func stillScriptIsIdempotent() throws {
        let context = try #require(JSContext())
        context.evaluateScript(FigmaWrapperPage.addressScript)
        let embed = "https://embed.figma.com/design/KEY/slug?embed-host=cmux&node-id=12-2"
        context.evaluateScript("""
        window = this;
        location = { search: '?embed=' + encodeURIComponent('\(embed)') };
        URLSearchParams = function (search) {
          var map = {};
          search.replace(/^\\?/, '').split('&').forEach(function (pair) {
            var at = pair.indexOf('=');
            if (at >= 0) { map[decodeURIComponent(pair.slice(0, at))] = decodeURIComponent(pair.slice(at + 1)); }
          });
          this.get = function (name) { return name in map ? map[name] : null; };
        };
        matchMedia = function (query) { return { matches: false }; };
        replacedCount = 0;
        currentFrame = {
          src: 'https://embed.figma.com/design/KEY/slug?embed-host=cmux&node-id=12-2',
          setAttribute: function (k, v) { this[k] = v; },
          parentNode: {
            replaceChild: function (newChild, oldChild) {
              replacedCount++;
              currentFrame = newChild;
            }
          }
        };
        document = {
          querySelector: function (sel) { return sel === 'iframe' ? currentFrame : null; },
          createElement: function (tag) {
            return {
              src: '',
              setAttribute: function (k, v) { this[k] = v; },
              parentNode: currentFrame.parentNode
            };
          }
        };
        """)
        let result = context.evaluateScript(FigmaPlayScript.stillScript)
        #expect(context.exception == nil)
        #expect(result?.toBool() == false)
        #expect(context.evaluateScript("replacedCount")?.toInt32() == 0)

        // Control: the same script does replace a playing frame, so the still case above is a real refusal.
        context.evaluateScript("currentFrame.src = 'https://embed.figma.com/proto/KEY/slug?node-id=12-2';")
        let replaced = context.evaluateScript(FigmaPlayScript.stillScript)
        #expect(context.exception == nil)
        #expect(replaced?.toBool() == true)
        #expect(context.evaluateScript("replacedCount")?.toInt32() == 1)
    }
}
