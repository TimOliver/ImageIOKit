//
//  ViewController.swift
//  ImageIOKit
//
//  Created by Tim Oliver on 16/4/2023.
//

import UIKit
import ImageIO

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let bundle = Bundle.main.url(forResource: "ApplePark-PNG", withExtension: "jxl")!
            let imageSource = /*UIImage(contentsOfFile: bundle.path)*/ ImageSource(url: bundle)
            if #available(iOS 15.0, *) {
                //let image = imageSource?.preparingThumbnail(of: CGSize(width: 200, height: 200))
                let image = imageSource?.makeThumbnail(fittingSize: CGSize(width: 1000, height: 1000))
                let imageView = UIImageView(image: image)
                imageView.frame = CGRect(x: 10, y: 10, width: 500, height: 500)
                self.view.addSubview(imageView)
            }
        }
    }
}
