#include <Adafruit_NeoPixel.h>

#define LED_PIN    6
#define LED_COUNT  80
#define MAX_BRIGHT 178

Adafruit_NeoPixel strip(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800);

unsigned long lastSerial = 0;
const unsigned long fallbackMs = 3000;

bool effectDual = false;
uint8_t c1r = 0, c1g = 0, c1b = 255;    // birinci renk
uint8_t c2r = 255, c2g = 0, c2b = 0;    // ikinci renk

// animasyon
unsigned long lastTime = 0;
unsigned long animInterval = 60;        // ms, Flutter'dan da gelebilir

// desen
int patternOffset = 0;                  // tam adım
const int patternSize = 8;              // 4 + 4
float subPhase = 0.0f;                  // 0..1 arası, iki adım arasında

void setAll(uint8_t r, uint8_t g, uint8_t b) {
  for (int i = 0; i < LED_COUNT; i++) {
    strip.setPixelColor(i, strip.Color(r, g, b));
  }
  strip.show();
}

// belirli bir offset için (kesintisiz) LED'in rengini hesapla
void getColorAt(int ledIndex, int offset, uint8_t &r, uint8_t &g, uint8_t &b) {
  int pos = (ledIndex + offset) % patternSize;  // 0..7

  // yumuşak kenar: 0-2 tam c1, 3 karışım, 4 karışım, 5-7 tam c2
  float w1 = 1.0f;
  float w2 = 0.0f;

  if (pos == 3) {
    w1 = 0.7f;
    w2 = 0.3f;
  } else if (pos == 4) {
    w1 = 0.3f;
    w2 = 0.7f;
  } else if (pos >= 5) {
    w1 = 0.0f;
    w2 = 1.0f;
  }

  r = (uint8_t)(c1r * w1 + c2r * w2);
  g = (uint8_t)(c1g * w1 + c2g * w2);
  b = (uint8_t)(c1b * w1 + c2b * w2);
}

// asıl çizim: iki offset arasında lerp
void drawDualRotatingSmooth() {
  for (int i = 0; i < LED_COUNT; i++) {
    uint8_t rA, gA, bA;
    uint8_t rB, gB, bB;

    // şimdi
    getColorAt(i, patternOffset, rA, gA, bA);
    // bir sonraki adım
    int nextOffset = (patternOffset + 1) % patternSize;
    getColorAt(i, nextOffset, rB, gB, bB);

    // subPhase ile karıştır
    float t = subPhase; // 0..1
    uint8_t r = (uint8_t)(rA * (1.0f - t) + rB * t);
    uint8_t g = (uint8_t)(gA * (1.0f - t) + gB * t);
    uint8_t b = (uint8_t)(bA * (1.0f - t) + bB * t);

    strip.setPixelColor(i, strip.Color(r, g, b));
  }
  strip.show();
}

void setup() {
  strip.begin();
  strip.setBrightness(MAX_BRIGHT);
  setAll(0, 0, 255);
  Serial.begin(115200);
  lastTime = millis();
}

void loop() {
  // 1) Seri komutları al
  if (Serial.available()) {
    String line = Serial.readStringUntil('\n');
    line.trim();

    if (line.length() > 0) {
      if (line.charAt(0) == 'S') {
        int r, g, b;
        int scanned = sscanf(line.c_str(), "S %d %d %d", &r, &g, &b);
        if (scanned == 3) {
          r = constrain(r, 0, 255);
          g = constrain(g, 0, 255);
          b = constrain(b, 0, 255);
          effectDual = false;
          setAll(r, g, b);
          lastSerial = millis();
        }
      } else if (line.charAt(0) == 'D') {
        // D r1 g1 b1 r2 g2 b2 [speedMs]
        int r1,g1,b1,r2,g2,b2, spd;
        int scanned = sscanf(
          line.c_str(),
          "D %d %d %d %d %d %d %d",
          &r1,&g1,&b1,&r2,&g2,&b2,&spd
        );
        if (scanned >= 6) {
          c1r = constrain(r1,0,255);
          c1g = constrain(g1,0,255);
          c1b = constrain(b1,0,255);
          c2r = constrain(r2,0,255);
          c2g = constrain(g2,0,255);
          c2b = constrain(b2,0,255);
          effectDual = true;

          if (scanned == 7) {
            spd = max(10, min(spd, 500));
            animInterval = (unsigned long)spd;
          } else {
            animInterval = 60;
          }

          // yeni komut gelince anında çiz
          drawDualRotatingSmooth();
          lastSerial = millis();
        }
      }
    }
  }

  // 2) Animasyonu akıt
  if (effectDual) {
    unsigned long now = millis();
    unsigned long dt = now - lastTime;
    lastTime = now;

    // animInterval kadar sürede bir adım
    // dt'yi orana çevir
    float inc = (float)dt / (float)animInterval;
    subPhase += inc;

    // 1'i geçerse bir tam adım ilerle
    while (subPhase >= 1.0f) {
      subPhase -= 1.0f;
      patternOffset = (patternOffset + 1) % patternSize;
    }

    drawDualRotatingSmooth();
  } else {
    if (millis() - lastSerial > fallbackMs) {
      setAll(0, 0, 255);
      lastSerial = millis();
    }
  }
}
