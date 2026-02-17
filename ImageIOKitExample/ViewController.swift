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

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let bundle = Bundle.main.url(forResource: "ApplePark", withExtension: "jxl")!
            let imageSource = /*UIImage(contentsOfFile: bundle.path)*/ ImageSource(url: bundle)
            if #available(iOS 15.0, *) {
                //let image = imageSource?.preparingThumbnail(of: CGSize(width: 200, height: 200))
                let image = imageSource?.makeThumbnail(fittingSize: CGSize(width: 1200, height: 2000))
                let imageView = UIImageView(image: image)
                imageView.frame = CGRect(x: 10, y: 10, width: 500, height: 500)
                self.view.addSubview(imageView)
            }
        }

//        let bundle = Bundle.main.url(forResource: "ApplePark", withExtension: "jxl")!
//        let image = makeThumbnailWithImageIO(url: bundle, fittingSize: CGSize(width: 1200, height: 2000))
//        print(image)
    }

    /// Same resize operation using Apple's ImageIO framework for comparison.
//    func makeThumbnailWithImageIO(url: URL, fittingSize: CGSize) -> UIImage? {
//        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
//        let maxDimension = max(fittingSize.width, fittingSize.height)
//        let options: [CFString: Any] = [
//            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
//            kCGImageSourceCreateThumbnailFromImageAlways: true,
//            kCGImageSourceCreateThumbnailWithTransform: true
//        ]
//        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
//            return nil
//        }
//        return UIImage(cgImage: cgImage)
//    }
}
