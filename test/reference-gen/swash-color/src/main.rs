// Original code, part of the ttf library for Ceramic.
// Copyright (c) 2026 Jeremy Faivre, licensed under MIT. See LICENSE.
//
// Renders color glyphs with swash the way GPUI's CosmicTextSystem does for
// emoji (`Render::new(&[ColorOutline(0), ColorBitmap(BestFit)])`, alpha
// format), without hinting (the ttf rasterizer does not hint), and prints
// the placements and RGBA pixels as JSON (test/reference/color.json).
//
// Usage (from test/): cargo run --offline --release --manifest-path reference-gen/swash-color/Cargo.toml > reference/color.json
use swash::scale::image::Content;
use swash::scale::{Render, ScaleContext, Source, StrikeWith};
use swash::zeno::{Format, Vector};
use swash::FontRef;

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64(data: &[u8]) -> String {
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { B64[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64[n as usize & 63] as char } else { '=' });
    }
    out
}

fn render_cases(file: &str, path: &str, index: u32, cases: &[(u32, f32, f32, f32)], pixels: bool, out: &mut Vec<String>) {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(_) => return,
    };
    let font = FontRef::from_index(&data, index as usize).unwrap();
    let mut ctx = ScaleContext::new();
    let mut entries = Vec::new();
    for &(cp, size, ox, oy) in cases {
        let gid = font.charmap().map(cp);
        let mut scaler = ctx.builder(font).size(size).hint(false).build();
        let image = Render::new(&[Source::ColorOutline(0), Source::ColorBitmap(StrikeWith::BestFit)])
            .format(Format::Alpha)
            .offset(Vector::new(ox, oy))
            .render(&mut scaler, gid);
        let entry = match image {
            Some(image) if image.content == Content::Color => {
                let p = image.placement;
                let data = if pixels { format!("\"{}\"", base64(&image.data)) } else { "null".to_string() };
                let sum: u64 = image.data.iter().map(|&v| v as u64).sum();
                format!(
                    "{{\"cp\": {}, \"gid\": {}, \"size\": {}, \"offset\": [{}, {}], \"left\": {}, \"top\": {}, \"width\": {}, \"height\": {}, \"sum\": {}, \"rgba\": {}}}",
                    cp, gid, size, ox, oy, p.left, p.top, p.width, p.height, sum, data
                )
            }
            _ => format!("{{\"cp\": {}, \"gid\": {}, \"size\": {}, \"offset\": [{}, {}], \"none\": true}}", cp, gid, size, ox, oy),
        };
        entries.push(entry);
    }
    out.push(format!(
        "{{\"file\": \"{}\", \"index\": {}, \"glyphs\": [\n    {}\n  ]}}",
        file,
        index,
        entries.join(",\n    ")
    ));
}

fn main() {
    let mut fonts = Vec::new();
    let sizes = [8.0f32, 15.5, 16.0, 20.0, 24.0, 40.0, 48.7, 64.0];
    // U+1F603 (16-bit grey and alpha PNG) is left out: swash 0.2.10 panics on
    // 16-bit PNG images (`normalize` indexes past the row), the ttf tests
    // check it against the pixels of the generator instead
    let mut cases = Vec::new();
    for &cp in &[0x41u32, 0x1F600, 0x1F601, 0x1F602, 0x1F604, 0x20] {
        for &size in &sizes {
            cases.push((cp, size, 0.0, 0.0));
        }
    }
    render_cases("SbixTest.ttf", "fonts/SbixTest.ttf", 0, &cases, true, &mut fonts);

    let mut cases = Vec::new();
    for &cp in &[0x41u32, 0x1F600, 0x42] {
        for &size in &sizes {
            cases.push((cp, size, 0.0, 0.0));
        }
    }
    render_cases("CbdtTest.ttf", "fonts/CbdtTest.ttf", 0, &cases, true, &mut fonts);

    let mut cases = Vec::new();
    for &cp in &[0x1F600u32, 0x1F1EB, 0x41] {
        for &size in &sizes {
            cases.push((cp, size, 0.0, 0.0));
            cases.push((cp, size, 0.25, 0.0));
        }
    }
    render_cases("ColrTest.ttf", "fonts/ColrTest.ttf", 0, &cases, true, &mut fonts);

    // Apple Color Emoji (macOS only; the tests skip it when the file is missing):
    // grinning face, a `flip` glyph source and its mirrored glyph, regional
    // indicators, a skin tone modifier and the variation selector
    let apple = "/System/Library/Fonts/Apple Color Emoji.ttc";
    let mut cases = Vec::new();
    for &cp in &[0x1F600u32, 0x1F3C3, 0x1F1EB, 0x1F3FD, 0x2764, 0xFE0F, 0x200D] {
        for &size in &[13.0f32, 16.0, 32.0] {
            cases.push((cp, size, 0.0, 0.0));
        }
    }
    render_cases(apple, apple, 0, &cases, true, &mut fonts);

    println!("{{\n  \"tool\": \"swash 0.2.10\",\n  \"fonts\": [\n  {}\n  ]\n}}", fonts.join(",\n  "));
}
