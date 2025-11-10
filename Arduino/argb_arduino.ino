//Open this on Arduino IDE
#include <Adafruit_NeoPixel.h>

#define LED_PIN    6
#define LED_COUNT  80   // 10 fan x 8 led
#define MAX_BRIGHT 178  // %70 of 255

Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);

unsigned long lastSerial = 0;
const unsigned long fallbackMs = 3000; // 3 sn komut gelmezse maviye dön

void setAll(uint8_t r, uint8_t g, uint8_t b) {
  // burada parlaklık sınırını uygularız
  // setBrightness global çalıştığı için onu sabit %70’te tutalım
  for (int i = 0; i < LED_COUNT; i++) {
    strip.setPixelColor(i, strip.Color(r, g, b));
  }
  strip.show();
}

void setup() {
  strip.begin();
  strip.setBrightness(MAX_BRIGHT);  // global cap %70
  setAll(0, 0, 255);                // varsayılan mavi
  Serial.begin(115200);             // PC buraya bağlanacak
}

void loop() {
  // Seri veri geldi mi?
  if (Serial.available()) {
    String line = Serial.readStringUntil('\n');
    line.trim();
    // Beklenen format: S R G B
    if (line.length() > 0 && line.charAt(0) == 'S') {
      int r, g, b;
      // örnek: "S 255 0 0"
      int scanned = sscanf(line.c_str(), "S %d %d %d", &r, &g, &b);
      if (scanned == 3) {
        // Değerleri 0-255 arasında tut
        r = constrain(r, 0, 255);
        g = constrain(g, 0, 255);
        b = constrain(b, 0, 255);
        setAll(r, g, b);
        lastSerial = millis();
      }
    }
  }

  // 3 saniye PC’den komut gelmezse tekrar maviye dön
  if (millis() - lastSerial > fallbackMs) {
    setAll(0, 0, 255);
    lastSerial = millis(); // tekrar tekrar yazmasın
  }
}
