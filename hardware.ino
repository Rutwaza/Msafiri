/*
  SpotLight Transit Device Firmware
  Board: ESP32 D1 mini
  Peripherals:
  - A7670C GSM modem
  - NEO-6M GPS
  - MFRC522 RFID

  What this firmware does:
  1) Every ~4s pushes live GPS telemetry to Firebase RTDB:
     /devices/{BUS_ID}/-autoKey
  2) Writes device metadata (route, plate, agency, sits) to:
     /devices/{BUS_ID}
  3) Reads RFID cards and sends tap events to your Cloud Function endpoint.
*/

#include <TinyGPSPlus.h>
#include <HardwareSerial.h>
#include <SPI.h>
#include <MFRC522.h>

// ---------------- PINS (adjust to your wiring) ----------------
#define GPS_RX 16
#define GPS_TX 17

#define MODEM_RX 21
#define MODEM_TX 22

#define RFID_SS 5
#define RFID_RST 4

#define LED_STATUS 2

// ---------------- NETWORK + DEVICE CONFIG ----------------
const char* APN = "internet";
const char* FIREBASE_HOST = "spotlight-traffic-prod-default-rtdb.firebaseio.com";
const char* FIREBASE_AUTH = "AIzaSyDLTVlu8D53IRz2FIMUh6RkN3XbbQN-xuE";

// Device identity
const char* BUS_ID = "Ritco_Bus_1";
const char* AGENCY_NAME = "Ritco";
const char* PLATE_NUMBER = "RAA123A";
const int DEFAULT_SITS = 28;

// Cloud Function for RFID tap event (fill after deploy)
const char* TAP_ENDPOINT =
    "https://us-central1-bussinessfinder-327f5.cloudfunctions.net/tapCard";
const char* DEVICE_SECRET = "Spot_Rt_01";

const unsigned long TELEMETRY_INTERVAL_MS = 4000;
const unsigned long META_INTERVAL_MS = 60000;
const unsigned long RFID_COOLDOWN_MS = 8000;

// ---------------- GLOBALS ----------------
HardwareSerial neogps(2);
HardwareSerial SerialAT(1);
TinyGPSPlus gps;
MFRC522 mfrc522(RFID_SS, RFID_RST);

bool gsmReady = false;
unsigned long lastTelemetryMs = 0;
unsigned long lastMetaMs = 0;
unsigned long lastRfidMs = 0;
double lastLat = 0.0;
double lastLng = 0.0;
String lastUid = "";

// ---------------- LED ----------------
void ledBlink(int onMs, int offMs, int times) {
  for (int i = 0; i < times; i++) {
    digitalWrite(LED_STATUS, HIGH);
    delay(onMs);
    digitalWrite(LED_STATUS, LOW);
    delay(offMs);
  }
}

void ledBootPattern() {
  digitalWrite(LED_STATUS, HIGH);
  delay(1200);
  digitalWrite(LED_STATUS, LOW);
}

void ledOkTick() {
  digitalWrite(LED_STATUS, HIGH);
  delay(80);
  digitalWrite(LED_STATUS, LOW);
}

// ---------------- AT HELPERS ----------------
String sendAT(const String& cmd, int timeoutMs = 2500) {
  while (SerialAT.available()) SerialAT.read();
  SerialAT.println(cmd);

  unsigned long start = millis();
  String resp = "";
  while (millis() - start < (unsigned long)timeoutMs) {
    while (SerialAT.available()) {
      resp += (char)SerialAT.read();
    }
  }
  Serial.println("AT> " + cmd);
  Serial.println(resp);
  return resp;
}

bool expectAT(const String& cmd, const String& expected, int timeoutMs = 2500) {
  return sendAT(cmd, timeoutMs).indexOf(expected) >= 0;
}

bool httpSend(const String& url, const String& body, int method) {
  // method: 0=GET, 1=POST, 4=PUT, 5=DELETE (module dependent)
  sendAT("AT+HTTPTERM", 1000);
  if (sendAT("AT+HTTPINIT", 3000).indexOf("OK") < 0) return false;

  sendAT("AT+HTTPSSL=1");
  sendAT("AT+HTTPPARA=\"CID\",1");
  sendAT("AT+HTTPPARA=\"URL\",\"" + url + "\"");
  sendAT("AT+HTTPPARA=\"CONTENT\",\"application/json\"");
  sendAT("AT+HTTPDATA=" + String(body.length()) + ",6000");
  delay(200);
  SerialAT.print(body);
  delay(300);

  String actionResp = sendAT("AT+HTTPACTION=" + String(method), 12000);
  sendAT("AT+HTTPTERM", 1000);

  return actionResp.indexOf(",200,") >= 0 || actionResp.indexOf(",201,") >= 0;
}

// ---------------- GSM ----------------
bool initGSM() {
  if (!expectAT("AT", "OK")) return false;
  sendAT("ATE0");
  if (!expectAT("AT+CPIN?", "READY")) return false;

  for (int i = 0; i < 15; i++) {
    if (expectAT("AT+CREG?", "0,1") || expectAT("AT+CREG?", "0,5")) break;
    delay(1200);
    if (i == 14) return false;
  }

  sendAT("AT+CGDCONT=1,\"IP\",\"" + String(APN) + "\"");
  sendAT("AT+CGATT=1");
  delay(1000);
  if (!expectAT("AT+CGACT=1,1", "OK", 7000)) return false;

  gsmReady = true;
  return true;
}

float readBatteryV() {
  String resp = sendAT("AT+CBC", 2200);
  int idx = resp.indexOf("+CBC:");
  if (idx < 0) return 0.0f;
  // Typical format includes voltage near the end.
  int comma2 = resp.lastIndexOf(',');
  if (comma2 < 0) return 0.0f;
  String mv = resp.substring(comma2 + 1);
  mv.trim();
  float millivolts = mv.toFloat();
  if (millivolts > 100) return millivolts / 1000.0f;
  return millivolts;
}

// ---------------- JSON BUILDERS ----------------
String telemetryJson() {
  float bat = readBatteryV();
  String json = "{";
  json += "\"lat\":" + String(gps.location.lat(), 6);
  json += ",\"lng\":" + String(gps.location.lng(), 6);
  json += ",\"spd\":" + String(gps.speed.isValid() ? gps.speed.kmph() : 0.0, 1);
  json += ",\"hdop\":" + String(gps.hdop.isValid() ? gps.hdop.hdop() : 99.9, 1);
  json += ",\"alt\":" + String(gps.altitude.isValid() ? gps.altitude.meters() : 0.0, 1);
  json += ",\"bat\":" + String(bat, 2);
  json += ",\"ts\":" + String((unsigned long)(millis() / 1000));
  json += "}";
  return json;
}

String metadataJson() {
  String json = "{";
  json += "\"sits\":" + String(DEFAULT_SITS);
  json += ",\"agencyName\":\"" + String(AGENCY_NAME) + "\"";
  json += ",\"plateNumber\":\"" + String(PLATE_NUMBER) + "\"";
  json += ",\"deviceSecret\":\"" + String(DEVICE_SECRET) + "\"";
  json += "}";
  return json;
}

String tapJson(const String& uidHex) {
  String json = "{";
  json += "\"busId\":\"" + String(BUS_ID) + "\"";
  json += ",\"plateNumber\":\"" + String(PLATE_NUMBER) + "\"";
  json += ",\"cardId\":\"" + uidHex + "\"";
  json += ",\"deviceSecret\":\"" + String(DEVICE_SECRET) + "\"";
  json += ",\"deviceTs\":" + String((unsigned long)(millis() / 1000));
  json += "}";
  return json;
}

// ---------------- FIREBASE + API ----------------
bool pushTelemetry() {
  String url = "https://" + String(FIREBASE_HOST) + "/devices/" + String(BUS_ID) +
               ".json?auth=" + String(FIREBASE_AUTH);
  return httpSend(url, telemetryJson(), 1);  // POST => generates -autoKey child
}

bool putMetadata() {
  // PUT metadata object to /devices/{BUS_ID}.json
  // If your modem FW does not support HTTPACTION=4, use cloud function proxy.
  String url = "https://" + String(FIREBASE_HOST) + "/devices/" + String(BUS_ID) +
               ".json?auth=" + String(FIREBASE_AUTH);
  return httpSend(url, metadataJson(), 4);
}

bool sendTapEvent(const String& uidHex) {
  return httpSend(String(TAP_ENDPOINT), tapJson(uidHex), 1);
}

// ---------------- RFID ----------------
String readUidHex() {
  if (!mfrc522.PICC_IsNewCardPresent()) return "";
  if (!mfrc522.PICC_ReadCardSerial()) return "";

  String uid = "";
  for (byte i = 0; i < mfrc522.uid.size; i++) {
    byte b = mfrc522.uid.uidByte[i];
    if (b < 0x10) uid += "0";
    uid += String(b, HEX);
  }
  uid.toUpperCase();
  mfrc522.PICC_HaltA();
  mfrc522.PCD_StopCrypto1();
  return uid;
}

void handleRfid() {
  String uid = readUidHex();
  if (uid.length() == 0) return;

  unsigned long now = millis();
  if (uid == lastUid && (now - lastRfidMs) < RFID_COOLDOWN_MS) return;

  lastUid = uid;
  lastRfidMs = now;
  Serial.println("RFID UID: " + uid);

  if (!gsmReady) return;
  if (sendTapEvent(uid)) {
    Serial.println("TAP EVENT OK");
    ledBlink(60, 60, 2);
  } else {
    Serial.println("TAP EVENT FAIL");
    ledBlink(200, 60, 2);
  }
}

// ---------------- SETUP + LOOP ----------------
void setup() {
  Serial.begin(115200);

  pinMode(LED_STATUS, OUTPUT);
  digitalWrite(LED_STATUS, LOW);
  ledBootPattern();

  neogps.begin(9600, SERIAL_8N1, GPS_RX, GPS_TX);
  SerialAT.begin(115200, SERIAL_8N1, MODEM_RX, MODEM_TX);

  SPI.begin();
  mfrc522.PCD_Init();
  delay(50);

  if (!initGSM()) {
    Serial.println("GSM init failed. Restarting...");
    delay(3000);
    ESP.restart();
  }

  // Try metadata write once at startup.
  putMetadata();
  lastMetaMs = millis();
}

void loop() {
  while (neogps.available()) {
    gps.encode(neogps.read());
  }

  handleRfid();

  if (!gsmReady) {
    initGSM();
    delay(200);
    return;
  }

  unsigned long now = millis();

  if ((now - lastMetaMs) >= META_INTERVAL_MS) {
    if (putMetadata()) {
      Serial.println("Metadata synced");
    } else {
      Serial.println("Metadata sync failed");
    }
    lastMetaMs = now;
  }

  if ((now - lastTelemetryMs) >= TELEMETRY_INTERVAL_MS) {
    lastTelemetryMs = now;

    if (!gps.location.isValid() || !gps.location.isUpdated()) {
      Serial.println("Waiting GPS update...");
      delay(30);
      return;
    }

    double lat = gps.location.lat();
    double lng = gps.location.lng();
    if (abs(lat - lastLat) < 0.00001 && abs(lng - lastLng) < 0.00001) {
      delay(20);
      return;
    }

    lastLat = lat;
    lastLng = lng;

    if (pushTelemetry()) {
      Serial.println("Telemetry OK");
      ledOkTick();
    } else {
      Serial.println("Telemetry FAIL");
      gsmReady = false;
    }
  }

  delay(25);
}
