# Сборка Радарчика без Xcode-проекта: SwiftPM собирает бинарник,
# а здесь он упаковывается в Radarchik.app и подписывается.
#
#   make test     — тесты логики (деньги, форматы, фраза, база)
#   make app      — собрать build/Radarchik.app
#   make run      — собрать и перезапустить
#   make install  — положить в ~/Applications (нужно для «Запускать при входе»)
#   make zip      — build/Radarchik.zip для релиза на GitHub
#   make docs     — скриншоты README, превью ссылки и петля GIF (docs/)
#   make promo    — ролики для X и Contra (launch/, в git не попадают)

APP_NAME  := Radarchik
BUILD_DIR := build
APP       := $(BUILD_DIR)/$(APP_NAME).app
CONFIG    ?= release

# Подпись постоянным сертификатом «Radarchik dev» (самоподписанный, создан
# в Связке ключей 2026-10-18), если он есть. Без постоянной подписи macOS после
# каждой пересборки сбрасывает выданные разрешения (Accessibility, Automation).
# Сертификата нет (другой мак) — подпись ad-hoc, сборка всё равно работает.
SIGN_IDENTITY ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"Radarchik dev"' && echo "Radarchik dev" || echo -)

.PHONY: app run test install zip docs promo clean

app:
	swift build -c $(CONFIG) --product $(APP_NAME)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	cp -R Support/en.lproj Support/ru.lproj "$(APP)/Contents/Resources/"
	cp Support/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"
	@echo "Готово: $(APP) (подпись: $(SIGN_IDENTITY))"

run: app
	-pkill -x $(APP_NAME)
	open "$(APP)"

test:
	swift test

install: app
	-pkill -x $(APP_NAME)
	mkdir -p ~/Applications
	rm -rf ~/Applications/$(APP_NAME).app
	cp -R "$(APP)" ~/Applications/
	open ~/Applications/$(APP_NAME).app

# Архив для GitHub Releases: ditto сохраняет подпись и атрибуты .app.
zip: app
	rm -f "$(BUILD_DIR)/$(APP_NAME).zip"
	ditto -c -k --keepParent "$(APP)" "$(BUILD_DIR)/$(APP_NAME).zip"
	@echo "Готово: $(BUILD_DIR)/$(APP_NAME).zip"

# Картинки рисует само приложение на выдуманных данных (Sources/Radarchik/Promo/).
docs:
	swift build --product $(APP_NAME)
	.build/debug/$(APP_NAME) --render-docs docs/screenshots/en --language en
	.build/debug/$(APP_NAME) --render-docs docs/screenshots/ru --language ru
	.build/debug/$(APP_NAME) --render-social docs/social-preview.png
	.build/debug/$(APP_NAME) --render-gif docs/notch-loop.gif

promo:
	swift build --product $(APP_NAME)
	mkdir -p launch
	.build/debug/$(APP_NAME) --render-promo launch/radarchik-promo-wide.mp4 --format wide
	.build/debug/$(APP_NAME) --render-promo launch/radarchik-promo-square.mp4 --format square

clean:
	rm -rf .build "$(BUILD_DIR)"
