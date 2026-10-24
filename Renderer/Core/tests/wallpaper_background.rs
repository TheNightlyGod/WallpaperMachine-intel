use objc2_core_graphics::{CGBitmapContextCreate, CGColorSpace};
use objc2_foundation::{NSPoint, NSRect, NSSize};
use objc2_quartz_core::{CAMetalLayer, CATransaction};
use wallpaper_core::{DisplayDesc, PlaceholderStyle};

fn check(label: &str, layer: &CAMetalLayer) {
    let mut pixels = [255u8; 8 * 8 * 4];
    let space = CGColorSpace::new_device_rgb().unwrap();
    let context = unsafe {
        CGBitmapContextCreate(pixels.as_mut_ptr().cast(), 8, 8, 8, 32, Some(&space), 1)
    }.unwrap();
    layer.renderInContext(&context);
    drop(context);
    println!("{label}: first RGBA pixel {:?}", &pixels[..4]);
    assert!(pixels.chunks_exact(4).all(|pixel| pixel == [0, 0, 0, 255]),
        "a missing drawable must cover the white host with opaque black");
}

fn main() {
    objc2::rc::autoreleasepool(|_| {
        let display = DisplayDesc::new(1, 0, 0, 16, 16, 2.0);
        let layer = display.build_metal_layer(&PlaceholderStyle::default());
        check("initial drawable unavailable", &layer);
        CATransaction::begin();
        CATransaction::setDisableActions(true);
        layer.setFrame(NSRect::new(NSPoint::ZERO, NSSize::new(12.0, 12.0)));
        layer.setContentsScale(1.0);
        layer.setDrawableSize(NSSize::new(12.0, 12.0));
        CATransaction::commit();
        check("resized drawable unavailable", &layer);
        let recreated = DisplayDesc::new(2, 100, 0, 8, 8, 1.0)
            .build_metal_layer(&PlaceholderStyle::default());
        check("recreated drawable unavailable", &recreated);
    });
}
