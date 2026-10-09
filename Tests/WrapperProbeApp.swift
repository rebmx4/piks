import UIKit
import WebKit

// Separate simulator-only app. This fixture is never included in the APIKS IPA.
@main
final class WrapperProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let mode = ProcessInfo.processInfo.arguments.contains("standard") ? WrapperInputMode.standard : .minimal
        let host = UIViewController()
        let web = WKWebView()
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.bounces = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        WrapperInputBaseline(web).apply(to: web, mode: mode)
        web.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.view.trailingAnchor)
        ])
        web.loadHTMLString(Self.html.replacingOccurrences(of: "__MODE__", with: mode.rawValue), baseURL: nil)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    private static let html = #"""
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <style>
    *{box-sizing:border-box}html,body{height:100%;margin:0;overflow:hidden}
    body{display:flex;flex-direction:column;font:18px -apple-system;background:#fff;color:#000}
    header{height:15%;display:flex;align-items:center;justify-content:space-around;flex-shrink:0}
    button{height:50px;min-width:90px;touch-action:manipulation}
    #timeline{height:35%;flex-shrink:0;background:#9cb9d1;touch-action:none;display:flex;align-items:center;justify-content:center}
    #effects{height:40%;flex-shrink:0;overflow:auto;touch-action:pan-y;-webkit-overflow-scrolling:touch}
    #effects div{height:60px;padding:18px;border-bottom:1px solid #999}
    footer{height:10%;flex-shrink:0;font-size:14px;display:flex;flex-wrap:wrap;gap:6px;align-items:center}
    </style></head><body>
    <header><button>Cut</button><button>Select</button><button>Keyframe</button></header>
    <div id="timeline">Timeline</div><div id="effects"></div>
    <footer><span>Mode:__MODE__</span><span id="tools">Tools:0</span><span id="swipes">Swipes:0</span><span id="cancels">Cancels:0</span><span id="scroll">Scroll:0</span></footer>
    <script>
    const timeline=document.querySelector('#timeline'),effects=document.querySelector('#effects');
    let tools=0,swipes=0,cancels=0,start=null;
    document.querySelectorAll('button').forEach(button=>button.onclick=()=>document.querySelector('#tools').textContent='Tools:'+(++tools));
    timeline.onpointerdown=event=>{start=event.clientX;timeline.setPointerCapture(event.pointerId)};
    timeline.onpointerup=event=>{if(start!==null&&Math.abs(event.clientX-start)>30)document.querySelector('#swipes').textContent='Swipes:'+(++swipes);start=null};
    timeline.onpointercancel=()=>{document.querySelector('#cancels').textContent='Cancels:'+(++cancels);start=null};
    for(let index=0;index<60;index++){const row=document.createElement('div');row.textContent='Effect '+index;effects.append(row)}
    effects.onscroll=()=>document.querySelector('#scroll').textContent='Scroll:'+Math.round(effects.scrollTop);
    </script></body></html>
    """#
}
