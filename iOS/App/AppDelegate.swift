//
//  AppDelegate.swift
//  App
//
//  Created by 唐佳诚 on 2021/8/17.
//

import UIKit
import Hummer

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        Hummer.startEngine()
//        Hummer.startEngine { entry in
//            print(entry)
//        }
        window = UIWindow(frame: UIScreen.main.bounds)
        let viewController = ViewController(url: "http://192.168.1.88:8000/index.js", params: ["a":"a"])
        let navigationController = UINavigationController(rootViewController: viewController)
        navigationController.navigationBar.isTranslucent = false;
        window?.rootViewController = navigationController;
        window?.makeKeyAndVisible()
        
        return true
    }

}

