//
//  AppDelegate.swift
//  ImpulseDistribution
//
//  Created by Peter Huber on 2021-10-06.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var appController: AppController!
    @IBOutlet var window: NSWindow!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application

        // The factory defaults for the user preferences. Preferences.ValueOf() falls back on its own if this never runs, so
        // nothing depends on the ordering here - it is done so that the values are visible to 'defaults read' and can be
        // overridden for a single run from the command line. See Preferences.swift.
        Preferences.RegisterFactoryDefaults()

        // The formula self-checks, if one was asked for on the command line. Each VerifySelf() writes its report to UserDefaults -
        // the app is sandboxed, so print() and /tmp are both dead ends - and this gate exists so that running them does not mean
        // editing this file and rebuilding every time. Nothing happens on a normal launch.
        //
        //     open -a ImpulseDistribution --args -PCH_Verify YES
        //     defaults read com.huberistech.ImpulseDistribution TurnLadderVerification
        //     defaults read com.huberistech.ImpulseDistribution DielectricStressVerification
        //     defaults read com.huberistech.ImpulseDistribution SheetCapacitanceVerification
        //     defaults read com.huberistech.ImpulseDistribution RegulatingWindingVerification
        //     defaults read com.huberistech.ImpulseDistribution MultiStartCapacitanceVerification
        if UserDefaults.standard.bool(forKey: "PCH_Verify") {

            TurnLadderModel.VerifySelf()
            DielectricStress.VerifySelf()
            RegulatingWinding.VerifySelf()
            UserDefaults.standard.set(Segment.VerifyMultiStartCapacitance().joined(separator: "\n"), forKey: "MultiStartCapacitanceVerification")

            // This one builds Segments, so it is async and the terminate has to wait for it rather than race it.
            Task {

                UserDefaults.standard.set(await Segment.VerifySheetCapacitance().joined(separator: "\n"), forKey: "SheetCapacitanceVerification")
                NSApp.terminate(nil)
            }

            return
        }

        // A scripted test run, if one was asked for on the command line. This does nothing at all on a normal launch -
        // it needs the -PCH_SelfTest launch argument - and when it does run it terminates the app itself. See
        // SelfTest.swift for how to invoke it and where the report comes out.
        SelfTest.RunIfRequested(controller: appController)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func application(_ sender:NSApplication, openFile filename:String) -> Bool
    {
        let fixedFileName = (filename as NSString).expandingTildeInPath
        
        let url = URL(fileURLWithPath: fixedFileName, isDirectory: false)
        
        return appController.doOpen(fileURL: url)
    }


}

