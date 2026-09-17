# 앱 아이콘

2026-09-18 확정한 [디자인 기준](design/asset-style-guide.md)에 맞춰 새로 제작했다. 기존의 유리·무광 입체 버스 아이콘을 대체한다.

- 형태: 정면 버스 평면 심볼. 넓은 창문, 짧은 행선지 패널, 두 전조등·거울·바퀴.
- 색상 목표: 밝은 회색 `#F5F6F8` 배경, 차분한 블루 `#42658C` 심볼. 생성 이미지의 픽셀은 목표 색상과 약간 다를 수 있다.
- 효과: 입체감·그림자·장식 배지·문자 없이 또렷한 실루엣을 사용한다.
- 도구: 내장 `image_gen`. 새 이미지 생성 후 `sips`로 1024×1024로 리사이즈했다.
- 최종 파일: `ios/BusWidgetApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
- 형식: 1024×1024 불투명 PNG. 배경은 네 모서리까지 채우고 모서리 마스킹은 iOS가 적용한다.

앱 내부 기능 아이콘은 작은 크기에서 선명한 SF Symbols를 사용한다. 새 앱 아이콘과 같은 정면 버스·평면 표현을 공유하며, 앱 아이콘 이미지를 화면 안에 장식으로 반복하지 않는다.

## 생성 프롬프트

> Use case: logo-brand. Create a final iOS app icon for a calm, accurate, minimal Korean bus arrival utility. One precise flat vector-style front-facing city bus symbol in solid muted slate blue #42658C, centered on a completely uniform near-white light gray #F5F6F8 full-bleed square background. Bus has a clean softly rounded rectangular body, one wide white windshield cutout, one short horizontal white destination slit above it, two tiny round white headlights, two small integrated side mirrors, and two short simple wheels. Balanced symmetrical geometric construction; confidently readable at 32px. Bus symbol overall occupies about 56% of canvas width and 60% of canvas height, generous even negative space around it. Modest corner rounding, medium-bold filled silhouette, carefully balanced proportions. A polished quiet public-transit wayfinding pictogram, editorial clarity. Exactly two flat colors, no outlines around the canvas. No 3D, no volume, no shadow, no gradients, no glass, no shiny reflections, no clay, no texture, no noise, no clock, no pin, no badge, no lettering, no numbers, no logo text, no decorative illustration. No rounded-square container drawn into the image: the square background extends to all edges, iOS applies masking. Output exactly one square 1024x1024 opaque PNG app icon.
