// cmux-rbf (#cm-73.41): execute the frame's pan with a deterministic DOM and timer queue.
import Foundation
import JavaScriptCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("FigmaPanScripts")
struct FigmaPanScriptTests {
    private func frame(path: String = "/design/KEY/slug", editor: Bool = false, drawn: Bool = true) throws -> JSContext {
        let c = try #require(JSContext())
        c.evaluateScript(FigmaMotionTests.browser)
        c.evaluateScript("""
        listenerOptions={};listenerCalls=[];
        window.addEventListener=function(name,f,options){listeners[name]=f;listenerOptions[name]=options;listenerCalls.push({name:name,options:options})};
        window.parent={postMessage:function(m,t){posted.push(m); targets.push(t)}}; targets=[];
        window.postMessage=window.parent.postMessage;
        location.hostname='www.figma.com'; location.pathname='\(path)';
        location.ancestorOrigins=['cmux-figma://cmux']; location.href='https://www.figma.com\(path)?node-id=12-2';
        operations=[]; location.replace=function(s){operations.push('replace'); replaced=s};
        time=0; performance={now:function(){return time},timeOrigin:1000}; Date.now=function(){return time+1000};
        raf=[]; canvas=false; requestAnimationFrame=function(f){raf.push(f)}; document.querySelector=function(){return canvas?target:null};
        events=[]; hits=[]; wheelTails=[];
        eventAt=function(i){return events[i]||{}}; reportAt=function(i){return posted[i]||{}};
        realEvents=[]; dispatchVisits=[]; dispatchDepth=0;
        dispatchOn=function(t,label,e){e.target=t;e.targetID=label;dispatchVisits.push({type:e.type,trusted:e.isTrusted});
          dispatchDepth++;if(dispatchDepth<4 && listeners[e.type])listeners[e.type](e);dispatchDepth--;
          events.push(e);operations.push(e.type);return !e.defaultPrevented};
        target={tagName:'CANVAS',isConnected:true,dispatchEvent:function(e){return dispatchOn(this,'start',e)}};
        other={isConnected:true,dispatchEvent:function(e){return dispatchOn(this,'other',e)}};
        document.documentElement={isConnected:true,dispatchEvent:function(e){return dispatchOn(this,'root',e)}};
        document.elementFromPoint=function(x,y){hits.push([x,y]);return target};
        commonFields={clientX:0,clientY:0,screenX:0,screenY:0,button:0,buttons:0,shiftKey:false,ctrlKey:false,
          metaKey:false,altKey:false,bubbles:false,cancelable:false,composed:false,detail:0,view:null,
          relatedTarget:null,movementX:0,movementY:0};
        pointerFields={pointerId:0,pointerType:'',isPrimary:false,width:1,height:1,pressure:0,
          tangentialPressure:0,tiltX:0,tiltY:0,twist:0,altitudeAngle:0,azimuthAngle:0};
        eventInit=function(e,type,init,pointer){var fields=Object.assign({},commonFields,pointer?pointerFields:{});
          Object.keys(fields).forEach(function(k){Object.defineProperty(e,k,{value:init[k]===undefined?fields[k]:init[k],configurable:true})});
          e.type=type;e.family=pointer?'pointer':'mouse';Object.defineProperty(e,'isTrusted',{value:false,configurable:true});
          e.defaultPrevented=false;e.immediateStopped=false;
          e.preventDefault=function(){if(this.cancelable)this.defaultPrevented=true};
          e.stopImmediatePropagation=function(){this.immediateStopped=true}};
        PointerEvent=function(type,init){eventInit(this,type,init,true)};
        MouseEvent=function(type,init){eventInit(this,type,init,false)};
        input=function(type,init){var p=Object.assign({clientX:300,clientY:200,screenX:1300,screenY:1200,
          button:type==='pointermove'?-1:0,buttons:/(up|cancel)$/.test(type)?0:1,
          shiftKey:true,bubbles:true,cancelable:true,composed:true,pointerId:1,pointerType:'mouse',isPrimary:true},init||{});
          var e=type.indexOf('pointer')===0?new PointerEvent(type,p):new MouseEvent(type,p);
          Object.defineProperty(e,'isTrusted',{value:p.trusted!==false,configurable:true});e.target=p.target||target;
          if(listeners[type])listeners[type](e);
          if(!e.immediateStopped){realEvents.push(e);operations.push('real:'+type)}return e};
        timerID=0; timers={};
        setTimeout=function(f,ms){var id=++timerID;timers[id]={at:time+ms,f:f};return id};
        clearTimeout=function(id){delete timers[id]};
        advance=function(ms){var end=time+ms;while(true){var id=null;Object.keys(timers).forEach(function(k){
          if(timers[k].at<=end && (id===null || timers[k].at<timers[id].at))id=k});
          if(id===null)break;time=timers[id].at;var f=timers[id].f;delete timers[id];f()}time=end};
        wheel=function(init){var e=Object.assign({deltaX:0,deltaY:0,deltaMode:0,clientX:300,clientY:200,
          shiftKey:false,ctrlKey:false,metaKey:false,altKey:false,buttons:0,defaultPrevented:false,immediateStopped:false,
          preventDefault:function(){this.defaultPrevented=true},stopImmediatePropagation:function(){this.immediateStopped=true}},init);
          if(listeners.wheel)listeners.wheel(e);if(!e.immediateStopped)wheelTails.push(e);return e};
        """)
        if editor { c.evaluateScript("window.parent=window") }
        c.evaluateScript(FigmaMotion.clockScript)
        try #require(c.exception == nil, "frame script failed: \(String(describing: c.exception))")
        if drawn { c.evaluateScript("canvas=true;while(raf.length)raf.shift()()") }
        try #require(c.exception == nil, "drawn setup failed: \(String(describing: c.exception))")
        c.evaluateScript("posted=[];targets=[]")
        return c
    }

    private func check(_ c: JSContext, _ expression: String) throws -> Bool {
        let result = c.evaluateScript(expression)
        try #require(c.exception == nil, "harness execution failed: \(String(describing: c.exception))")
        return result?.toBool() == true
    }

    /// An excluded-event case first proves a taken-event twin, so an absent pan is red too.
    private func takenTwin() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaY:10}).defaultPrevented && eventAt(0).type==='pointerdown'"), "taken-event twin must pan")
    }

    @Test func plainWheelPreventsDefaultAndDragsFromThePointer() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaX:12,deltaY:30}).defaultPrevented"))
        #expect(try check(c, "events.length===4 && eventAt(0).type==='pointerdown' && eventAt(1).type==='mousedown' && eventAt(2).type==='pointermove' && eventAt(3).type==='mousemove'"))
        #expect(try check(c, "eventAt(0).clientX===300 && eventAt(0).clientY===200 && eventAt(2).clientX===288 && eventAt(2).clientY===170"))
        #expect(try check(c, "eventAt(0).pointerId===1 && eventAt(0).pointerType==='mouse' && eventAt(0).isPrimary===true && eventAt(0).button===0 && eventAt(2).button===-1"))
        #expect(try check(c, "events.every(function(e){return e.buttons===1 && e.bubbles && e.cancelable && e.composed})"))
        #expect(try check(c, "document.elementFromPoint=function(){return other};wheel({deltaY:1});events.every(function(e){return e.targetID==='start'})"))
    }

    @Test func lineDeltasScaleBySixteen() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaX:2,deltaY:-3,deltaMode:1}).defaultPrevented && eventAt(2).clientX===268 && eventAt(2).clientY===248"))
    }

    @Test func wheelOverControlsDragsTheCanvasFromTheOriginalPointer() throws {
        for tag in ["BUTTON", "A", "svg", "path"] {
            for dy in [100, 50] {
                let c = try frame()
                #expect(try check(c, "other.tagName='\(tag)';document.elementFromPoint=function(){return other};wheel({clientX:519,clientY:574,deltaY:\(dy)}).defaultPrevented"))
                #expect(try check(c, "events.length===4 && events.every(function(e){return e.target===target})"), "the control and its glyph never receive the synthetic drag")
                #expect(try check(c, "eventAt(0).clientX===519 && eventAt(0).clientY===574 && eventAt(2).clientX===519 && eventAt(2).clientY===574-\(dy)"), "retargeting preserves the pointer and the exact wheel delta")
                #expect(try check(c, "wheel({deltaY:5});advance(150);events.length===8 && events.every(function(e){return e.target===target}) && eventAt(6).type==='pointerup' && eventAt(6).clientY===569-\(dy) && reportAt(1).steps===2"), "moves and release keep the canvas target")
            }
        }
    }

    @Test func wheelOverAControlWithoutACanvasNeverPressesTheControl() throws {
        try takenTwin()
        let c = try frame()
        #expect(try check(c, "other.tagName='BUTTON';document.elementFromPoint=function(){return other};canvas=false;wheel({deltaY:100}).defaultPrevented"))
        #expect(try check(c, "events.length===0 && posted.length===0 && Object.keys(timers).length===0 && wheelTails.length===0"), "a canvas removed after drawing cannot fall back to dragging the control or delivering its wheel")
    }

    @Test func controlStartedWheelStopsEveryStepUntilReleaseAndThenCanvasWheelPassesThrough() throws {
        let c = try frame()
        #expect(try check(c, "other.tagName='BUTTON';document.elementFromPoint=function(){return other};wheel({deltaY:100}).immediateStopped && wheelTails.length===0"), "the original control wheel never reaches Figma's later handlers")
        #expect(try check(c, "document.elementFromPoint=function(){return target};wheel({deltaY:50}).immediateStopped && wheelTails.length===0"), "later steps of the same control-started drag remain consumed")
        #expect(try check(c, "advance(150);!wheel({deltaY:10}).immediateStopped && wheelTails.length===1"), "a new canvas-started gesture keeps its original propagation")
    }

    @Test func pageDeltasAreLeftToFigmaAndEndAnOpenDrag() throws {
        try takenTwin()
        let c = try frame()
        #expect(try check(c, "!wheel({deltaY:1,deltaMode:2}).defaultPrevented && events.length===0"))
        #expect(try check(c, "wheel({deltaY:10});!wheel({deltaY:1,deltaMode:2}).defaultPrevented && eventAt(4).type==='pointerup' && eventAt(5).type==='mouseup'"))
    }

    @Test func successiveStepsAccumulateInOneDrag() throws {
        let c = try frame(path: "/file/KEY/slug")
        #expect(try check(c, "wheel({deltaX:10,deltaY:20});wheel({deltaX:-4,deltaY:3,clientX:900,clientY:800});events.length===6 && hits.length===1 && eventAt(4).clientX===294 && eventAt(4).clientY===177"))
    }

    @Test func eachStepRestartsTheOneHundredFiftyMillisecondEnd() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaY:10});advance(140);events.length===4"))
        #expect(try check(c, "wheel({deltaX:5});advance(149);events.length===6"))
        #expect(try check(c, "advance(1);events.length===8 && eventAt(6).type==='pointerup' && eventAt(7).type==='mouseup' && eventAt(6).clientX===295 && eventAt(6).clientY===190 && eventAt(6).button===0 && eventAt(6).buttons===0"))
        #expect(try check(c, "advance(500);events.length===8"))
    }

    @Test func zeroStepWhileIdleNeverStartsADrag() throws {
        try takenTwin()
        let c = try frame()
        #expect(try check(c, "wheel({}).defaultPrevented && events.length===0 && Object.keys(timers).length===0 && posted.length===0"))
    }

    @Test func shiftLocksTheFirstLargerAxisAndKeepsIt() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaX:10,deltaY:80,shiftKey:true});wheel({deltaX:60,deltaY:10,shiftKey:true});eventAt(4).clientX===300 && eventAt(4).clientY===110 && reportAt(0).axis==='down'"))
        let across = try frame()
        #expect(try check(across, "wheel({deltaX:20,deltaY:20,shiftKey:true});wheel({deltaX:5,deltaY:90,shiftKey:true});eventAt(4).clientX===275 && eventAt(4).clientY===200 && reportAt(0).axis==='across'"))
    }

    @Test func releasingShiftFreesTheAxisAndHoldingItAgainRelocks() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaX:10,deltaY:80,shiftKey:true});wheel({deltaX:60,deltaY:10});wheel({deltaX:20,deltaY:1,shiftKey:true});eventAt(6).clientX===220 && eventAt(6).clientY===110"))
    }

    @Test func controlWheelIsLeftToFigma() throws {
        try takenTwin()
        let c = try frame()
        #expect(try check(c, "!wheel({deltaY:10,ctrlKey:true}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func commandWheelIsLeftToFigma() throws {
        try takenTwin()
        let c = try frame()
        #expect(try check(c, "!wheel({deltaY:10,metaKey:true}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func modifierWheelEndsTheDragBeforeLeavingTheStepAlone() throws {
        for modifier in ["metaKey", "ctrlKey"] {
            let c = try frame()
            #expect(try check(c, "wheel({deltaX:4,deltaY:10});var zoom=wheel({deltaY:20,\(modifier):true});!zoom.defaultPrevented && operations.join(',')==='pointerdown,mousedown,pointermove,mousemove,pointerup,mouseup' && eventAt(4).clientX===296 && eventAt(4).clientY===190"))
            #expect(try check(c, "advance(200);events.length===6 && reportAt(1).phase==='end'"))
        }
    }

    @Test func playerWheelIsLeftToFigma() throws {
        try takenTwin()
        let c = try frame(path: "/proto/KEY/slug")
        #expect(try check(c, "!wheel({deltaY:10}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func otherPathsAndTheEditorAreLeftAlone() throws {
        try takenTwin()
        for path in ["/embed/interstitial", "/login", "/board/KEY/slug"] {
            let c = try frame(path: path)
            #expect(try check(c, "!wheel({deltaY:10}).defaultPrevented && events.length===0 && posted.length===0"))
        }
        let editor = try frame(editor: true)
        #expect(try check(editor, "!listeners.wheel && posted.length===0"))
    }

    @Test func pagehideEndsAnOpenDragAndClearsItsTimer() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaY:10});listeners.pagehide();operations.join(',')==='pointerdown,mousedown,pointermove,mousemove,pointerup,mouseup' && eventAt(4).clientY===190"))
        #expect(try check(c, "advance(200);events.length===6 && Object.keys(timers).length===0"))
    }

    @Test func stillAndPlayerCommandsEndTheDragBeforeReplacingThePage() throws {
        for kind in ["still", "player"] {
            let c = try frame()
            #expect(try check(c, "wheel({deltaY:10});listeners.message({source:window.parent,origin:'cmux-figma://cmux',data:{cmuxClockCommand:true,kind:'\(kind)'}});operations.join(',')==='pointerdown,mousedown,pointermove,mousemove,pointerup,mouseup,replace'"))
            #expect(try check(c, "advance(200);events.length===6"))
        }
    }

    @Test func reportsUseTheirOwnTagAndCarryTheAxisDeltasAndStepCount() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaX:10,deltaY:80,shiftKey:true});wheel({deltaY:5,shiftKey:true});advance(150);posted.length===2 && posted.every(function(r){return r.cmuxPanReport===true && !('cmuxClockReport' in r)})"))
        #expect(try check(c, "reportAt(0).phase==='start' && reportAt(0).axis==='down' && reportAt(0).dx===0 && reportAt(0).dy===80 && reportAt(1).phase==='end' && reportAt(1).steps===2 && targets.every(function(t){return t==='cmux-figma://cmux'})"))
    }

    @MainActor @Test func pageRelaysPanWithoutChangingItsFitReportAndRejectsForeignSenders() throws {
        let c = try #require(JSContext())
        c.evaluateScript(FigmaMotionTests.browser)
        c.evaluateScript(FigmaMotion.pageScript())
        try #require(c.exception == nil)
        #expect(try check(c, "var kept={cmuxClockReport:true,path:'/design/KEY/slug',drawn:true,player:false};listeners.message({source:frame.contentWindow,origin:'https://embed.figma.com',data:kept});posted=[];var pan={cmuxPanReport:true,phase:'start',axis:'down',dx:0,dy:80};listeners.message({source:frame.contentWindow,origin:'https://embed.figma.com',data:pan});posted.length===1 && posted[0].panReport===pan && window.__cmuxMotion.snapshot().report===kept"))
        #expect(try check(c, "posted=[];listeners.message({source:{},origin:'https://embed.figma.com',data:pan});listeners.message({source:frame.contentWindow,origin:'https://evil.invalid',data:pan});posted.length===0 && window.__cmuxMotion.snapshot().report===kept"))
        #if canImport(cmux_DEV) || canImport(cmux)
        // The native branch runs in the app suite, including its native mutation; the script harness has no app.
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: nil, renderInitialNavigation: false, chromeVisibility: .hidden)
        defer { panel.close() }
        let address = try FigmaPaneURL.destination(for: URL(string: "https://www.figma.com/design/KEY/slug")!, node: "12-2").url
        panel.publishObservedDocumentURL(address)
        panel.receiveFigmaMotionMessage(from: panel.webView, mainFrame: true, address: address,
                                       body: ["panReport": ["phase": "end", "steps": 1], "state": "playing"])
        #expect(panel.figmaMotionState == .still, "pan reports never reach applyFigmaMotionSnapshot")
        #endif
    }

    @Test func nestedPanReportsAreTaggedAndForeignWindowsAreIgnored() throws {
        let c = try frame()
        #expect(try check(c, "window.frames=[{}];listeners.message({source:window.frames[0],data:{cmuxPanReport:true,nested:false,phase:'end',steps:2}});posted.length===1 && reportAt(0).nested===true && reportAt(0).cmuxPanReport===true"))
        #expect(try check(c, "posted=[];listeners.message({source:{},data:{cmuxPanReport:true}});posted.length===0"))
    }

    @Test func wheelActsOnlyThroughPointerEventsAndTelemetry() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaY:10});advance(150);events.length===6 && events.every(function(e){return /^(pointer|mouse)(down|move|up)$/.test(e.type)}) && posted.length===2 && posted.every(function(r){return r.cmuxPanReport===true && !r.cmuxClockCommand}) && sent.length===0 && typeof replaced==='undefined'"))
    }

    // MARK: Mouse lock (cmux-rbf #cm-73.41, Scenario 329)

    private func takenMouseTwin() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:301,clientY:204}).defaultPrevented && events.length===1"), "taken mouse twin must lock")
    }

    @Test func mouseLocksOnItsFirstSmallMoveAndKeepsTheLargerAxis() throws {
        let across = try frame()
        #expect(try check(across, "input('pointerdown');var first=input('pointermove',{clientX:300.25,clientY:200.125});first.defaultPrevented && first.immediateStopped && events.length===1 && eventAt(0).clientY===200"))
        #expect(try check(across, "input('pointermove',{clientX:302,clientY:240});eventAt(1).clientX===302 && eventAt(1).clientY===200"))
        let down = try frame()
        #expect(try check(down, "input('pointerdown');input('pointermove',{clientX:300.125,clientY:200.25});input('pointermove',{clientX:340,clientY:202});events.length===2 && eventAt(1).clientX===300 && eventAt(1).clientY===202"))
    }

    @Test func mouseExactTieChoosesAcross() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:299.75,clientY:199.75});events.length===1 && eventAt(0).clientX===299.75 && eventAt(0).clientY===200 && reportAt(0).axis==='mouse-across'"))
    }

    @Test func mouseCopiesAllEventInitFieldsIncludingInheritedNonEnumerableFields() throws {
        for family in ["pointer", "mouse"] {
            for bubbles in [true, false] {
                let c = try frame()
                #expect(try check(c, """
                input('\(family)down');
                var raw=input('\(family)move',{clientX:310,clientY:203,screenX:1234,screenY:567,
                  pointerId:73,pointerType:'mouse',isPrimary:false,width:2,height:3,pressure:0.7,
                  tangentialPressure:0.2,tiltX:12,tiltY:-8,twist:23,altitudeAngle:0.6,azimuthAngle:0.9,
                  altKey:true,bubbles:\(bubbles),cancelable:\(bubbles),composed:\(bubbles),detail:7,
                  movementX:10,movementY:3,view:{name:'view'},relatedTarget:{name:'related'},target:other});
                var keys=Object.keys(commonFields).filter(function(k){return ['clientX','clientY','screenY','movementY'].indexOf(k)<0});
                if('\(family)'==='pointer')keys=keys.concat(Object.keys(pointerFields));
                events.length===1 && eventAt(0).target===other && eventAt(0).family==='\(family)' &&
                  eventAt(0).clientX===310 && eventAt(0).clientY===200 && eventAt(0).screenY===1200 && eventAt(0).movementY===0 &&
                  keys.every(function(k){return eventAt(0)[k]===raw[k]})
                """))
            }
        }
    }

    @Test func mouseReleasePairIsCopiedAndTheLockEndsOnPointerup() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:310,clientY:202});var up=input('pointerup',{clientX:330,clientY:240});up.defaultPrevented && up.immediateStopped && events.length===2 && eventAt(1).type==='pointerup' && eventAt(1).clientX===330 && eventAt(1).clientY===200 && reportAt(1).phase==='end'"))
        #expect(try check(c, "var up2=input('mouseup',{clientX:330,clientY:240});up2.defaultPrevented && up2.immediateStopped && events.length===3 && eventAt(2).type==='mouseup' && eventAt(2).clientY===200 && posted.length===2"))
        #expect(try check(c, "!input('mouseup',{clientX:330,clientY:240}).defaultPrevented && events.length===3"))
    }

    @Test func mouseEventsWithoutPointerEventsUseTheSameLock() throws {
        let c = try frame()
        #expect(try check(c, "input('mousedown');input('mousemove',{clientX:301,clientY:204});input('mousemove',{clientX:330,clientY:250});events.length===2 && eventAt(1).type==='mousemove' && eventAt(1).clientX===300 && eventAt(1).clientY===250"))
        #expect(try check(c, "input('mouseup',{clientX:350,clientY:260}).defaultPrevented && eventAt(2).type==='mouseup' && eventAt(2).clientX===300 && reportAt(1).phase==='end'"))
    }

    @Test func mouseWithoutShiftPassesThroughAndReleasingShiftEndsTheLock() throws {
        try takenMouseTwin()
        let c = try frame()
        #expect(try check(c, "input('pointerdown',{shiftKey:false});!input('pointermove',{clientX:310,clientY:210,shiftKey:false}).defaultPrevented && events.length===0"))
        #expect(try check(c, "input('pointermove',{clientX:320,clientY:211});var free=input('pointermove',{clientX:330,clientY:240,shiftKey:false});!free.defaultPrevented && !free.immediateStopped && events.length===1 && reportAt(1).phase==='end'"))
        #expect(try check(c, "input('pointermove',{clientX:330.125,clientY:242});eventAt(1).clientX===330 && eventAt(1).clientY===242"))
    }

    private func mouseModifierPassesAndEndsLock(_ modifier: String) throws {
        try takenMouseTwin()
        let c = try frame()
        #expect(try check(c, "input('pointerdown');!input('pointermove',{clientX:310,\(modifier):true}).defaultPrevented && events.length===0"))
        #expect(try check(c, "input('pointermove',{clientX:320,clientY:201});var free=input('pointermove',{clientX:340,clientY:220,\(modifier):true});!free.defaultPrevented && !free.immediateStopped && events.length===1 && reportAt(1).phase==='end'"))
    }

    @Test func commandMouseMoveNeverLocksAndEndsAnOpenLock() throws {
        try mouseModifierPassesAndEndsLock("metaKey")
    }

    @Test func controlMouseMoveNeverLocksAndEndsAnOpenLock() throws {
        try mouseModifierPassesAndEndsLock("ctrlKey")
    }

    @Test func shiftPressedMidMouseDragHoldsAtTheLastFreePoint() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown',{shiftKey:false});input('pointermove',{clientX:400,clientY:210,shiftKey:false});input('pointermove',{clientX:404,clientY:230});input('pointermove',{clientX:430,clientY:260});events.length===2 && eventAt(1).clientX===400 && eventAt(1).clientY===260"))
    }

    @Test func newPointerdownEndsTheOldMouseLockAndResetsItsAnchor() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:310,clientY:201});input('pointerdown',{clientX:1000,clientY:500});input('pointermove',{clientX:1001,clientY:505});events.length===2 && eventAt(1).clientX===1000 && eventAt(1).clientY===505 && reportAt(1).phase==='end' && reportAt(2).axis==='mouse-down'"))
    }

    @Test func pointercancelEndsAnActiveMouseLock() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:310,clientY:201});input('pointercancel');!input('pointermove',{clientX:330,clientY:240}).defaultPrevented && events.length===1 && reportAt(1).phase==='end'"))
    }

    @Test func untrustedMouseCopyReentersTheListenersWithoutBeingCopiedAgain() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:310,clientY:201});events.length===1 && dispatchVisits.length===1 && dispatchVisits[0].trusted===false && eventAt(0).isTrusted===false && !eventAt(0).defaultPrevented && !eventAt(0).immediateStopped"))
    }

    @Test func playerMouseDragIsUntouched() throws {
        try takenMouseTwin()
        let c = try frame(path: "/proto/KEY/slug")
        #expect(try check(c, "input('pointerdown');!input('pointermove',{clientX:310}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func mouseDragOnOtherPathsIsUntouched() throws {
        try takenMouseTwin()
        let c = try frame(path: "/embed/interstitial")
        #expect(try check(c, "input('pointerdown');!input('pointermove',{clientX:310}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func rightButtonMouseDragIsUntouched() throws {
        try takenMouseTwin()
        let c = try frame()
        #expect(try check(c, "input('pointerdown',{button:2,buttons:2});!input('pointermove',{buttons:2,clientX:310}).defaultPrevented && !input('pointerup',{button:2}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func untrustedMouseInputCannotStartOrEndTheRealMouseLock() throws {
        try takenMouseTwin()
        let c = try frame()
        #expect(try check(c, "input('pointerdown');!input('pointermove',{trusted:false,clientX:310}).defaultPrevented && events.length===0"))
        #expect(try check(c, "input('pointermove',{clientX:320,clientY:201});input('pointerup',{trusted:false});input('pointercancel',{trusted:false});input('pointermove',{clientX:330,clientY:240});events.length===2 && eventAt(1).clientY===200"))
        let down = try frame()
        #expect(try check(down, "input('pointerdown',{trusted:false});!input('pointermove',{clientX:310}).defaultPrevented && events.length===0"))
    }

    @Test func wheelWhileAnyMouseButtonIsHeldStartsNothing() throws {
        try takenTwin()
        let c = try frame()
        #expect(try check(c, "!wheel({deltaY:10,buttons:1}).defaultPrevented && !wheel({deltaY:10,buttons:2}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func mouseReportsItsAxisAndCountsOnlyPointermoveCopies() throws {
        for (dx, dy, axis) in [(10, 2, "across"), (2, 10, "down")] {
            let c = try frame()
            #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:300+\(dx),clientY:200+\(dy)});input('mousemove',{clientX:300+\(dx),clientY:200+\(dy)});input('pointerup');input('mouseup');posted.length===2 && posted.every(function(r){return r.cmuxPanReport===true && !r.cmuxClockReport}) && reportAt(0).axis==='mouse-\(axis)' && reportAt(1).phase==='end' && reportAt(1).steps===1 && targets.every(function(t){return t==='cmux-figma://cmux'})"))
        }
    }

    @Test func pointerupAloneEndsTheLockAndTheNextDragStartsClean() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:310,clientY:201});input('pointerup',{clientX:330,clientY:240});reportAt(1).phase==='end' && events.length===2"))
        #expect(try check(c, "input('pointerdown',{clientX:800,clientY:400,shiftKey:false});input('pointermove',{clientX:810,clientY:420,shiftKey:false});!input('mouseup',{clientX:810,clientY:420,shiftKey:false}).defaultPrevented && events.length===2 && posted.length===2"))
    }

    @Test func pointercancelClearsThePendingCompatibilityMouseup() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:310,clientY:201});input('pointerup',{clientX:330,clientY:240});input('pointercancel');!input('mouseup',{clientX:330,clientY:240}).defaultPrevented && events.length===2 && posted.length===2"))
    }

    @Test func mouseMoveWithNoLeftButtonEndsALostReleaseAndPassesThrough() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:310,clientY:201});var hover=input('pointermove',{clientX:330,clientY:240,buttons:0});!hover.defaultPrevented && !hover.immediateStopped && events.length===1 && reportAt(1).phase==='end'"))
    }

    @Test func realPointerdownEndsTheWheelDragBeforeFigmaSeesThePress() throws {
        let c = try frame()
        #expect(try check(c, "wheel({deltaY:10});var press=input('pointerdown',{clientX:500,clientY:400});!press.defaultPrevented && events.length===6 && operations.join(',')==='pointerdown,mousedown,pointermove,mousemove,pointerup,mouseup,real:pointerdown' && reportAt(1).phase==='end'"))
        #expect(try check(c, "advance(200);events.length===6 && Object.keys(timers).length===0"))
    }

    // MARK: Cold review fixes (cmux-rbf #cm-73.41)

    @Test func wheelWithZeroButtonsIsBlockedWhileTheRealMouseIsHeld() throws {
        try takenTwin()
        let c = try frame()
        #expect(try check(c, "input('pointerdown');!wheel({deltaY:10,buttons:0}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func wheelListenerCapturesAndExplicitlyDisablesPassiveDelivery() throws {
        let c = try frame()
        #expect(try check(c, "(listenerOptions.wheel||{}).capture===true && (listenerOptions.wheel||{}).passive===false"))
    }

    @Test func everyMouseListenerRunsInTheCapturePhase() throws {
        let c = try frame()
        for type in ["pointerdown", "mousedown", "pointermove", "mousemove", "pointerup", "mouseup", "pointercancel"] {
            #expect(try check(c, "listenerOptions['\(type)']===true"), "\(type) captures")
        }
    }

    @Test func wheelBeforeTheCanvasHasDrawnIsUntouched() throws {
        try takenTwin()
        let c = try frame(drawn: false)
        #expect(try check(c, "document.querySelector('canvas')===null && !wheel({deltaY:10}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func mouseBeforeTheCanvasHasDrawnIsUntouched() throws {
        try takenMouseTwin()
        let c = try frame(drawn: false)
        #expect(try check(c, "input('pointerdown');!input('pointermove',{clientX:310}).defaultPrevented && events.length===0 && posted.length===0"))
    }

    @Test func wheelReleaseFromADetachedTargetReachesTheLiveDocument() throws {
        for fallback in [false, true] {
            let c = try frame()
            let destination = fallback ? "null" : "other"
            let label = fallback ? "root" : "other"
            #expect(try check(c, "wheel({deltaX:5,deltaY:10});target.isConnected=false;var releaseHit=[];document.elementFromPoint=function(x,y){releaseHit=[x,y];return \(destination)};advance(150);events.length===6 && eventAt(4).type==='pointerup' && eventAt(5).type==='mouseup' && eventAt(4).targetID==='\(label)' && eventAt(5).targetID==='\(label)' && eventAt(4).clientX===295 && eventAt(4).clientY===190 && releaseHit[0]===295 && releaseHit[1]===190"))
        }
    }

    @Test func secondButtonPressWhileLeftIsHeldPreservesTheMouseLock() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown');input('pointermove',{clientX:301,clientY:210});var right=input('pointerdown',{button:2,buttons:3});var rightMouse=input('mousedown',{button:2,buttons:3});input('pointermove',{clientX:340,clientY:250,buttons:3});!right.defaultPrevented && !rightMouse.defaultPrevented && events.length===2 && eventAt(1).clientX===300 && eventAt(1).clientY===250 && eventAt(1).buttons===3 && posted.length===1"))
    }

    @Test func mouseCopiesHoldScreenAndZeroMovementOnTheConstrainedCoordinate() throws {
        for (dx, dy, across) in [(10, 3, true), (3, 10, false)] {
            let c = try frame()
            #expect(try check(c, """
            input('pointerdown');
            var originals=[input('pointermove',{clientX:300+\(dx),clientY:200+\(dy),screenX:1300+\(dx),screenY:1200+\(dy),movementX:\(dx),movementY:\(dy)}),
              input('pointerup',{clientX:340,clientY:250,screenX:1340,screenY:1250,movementX:30,movementY:40}),
              input('mouseup',{clientX:340,clientY:250,screenX:1340,screenY:1250,movementX:1,movementY:1})];
            var held=\(across)?'Y':'X', free=\(across)?'X':'Y';
            events.length===3 && events.every(function(e,i){return e['client'+held]===(\(across)?200:300) &&
              e['screen'+held]===(\(across)?1200:1300) && e['movement'+held]===0 &&
              e['client'+free]===originals[i]['client'+free] && e['screen'+free]===originals[i]['screen'+free] &&
              e['movement'+free]===originals[i]['movement'+free]})
            """))
        }
    }

    @Test func shiftMidDragHoldsScreenCoordinatesAtTheLastFreePoint() throws {
        let c = try frame()
        #expect(try check(c, "input('pointerdown',{shiftKey:false});input('pointermove',{clientX:400,clientY:210,screenX:1400,screenY:1210,shiftKey:false});input('pointermove',{clientX:404,clientY:230,screenX:1404,screenY:1230,movementX:4,movementY:20});input('pointermove',{clientX:430,clientY:260,screenX:1430,screenY:1260,movementX:26,movementY:30});events.length===2 && eventAt(1).clientX===400 && eventAt(1).screenX===1400 && eventAt(1).movementX===0 && eventAt(1).screenY===1260 && eventAt(1).movementY===30"))
    }
}
