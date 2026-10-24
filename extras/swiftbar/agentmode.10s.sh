#!/bin/zsh
# <xbar.title>agentmode</xbar.title>
# <xbar.version>v0.1.0</xbar.version>
# <xbar.author>ULookLookMe</xbar.author>
# <xbar.author.github>ULookLookMe</xbar.author.github>
# <xbar.desc>Shows whether agentmode keeps the Mac awake, and turns it on or off.</xbar.desc>
# <xbar.dependencies>agentmode</xbar.dependencies>
# <xbar.abouturl>https://github.com/ULookLookMe/agent-mode</xbar.abouturl>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# SwiftBar (and xbar) plugin for agentmode. It refreshes every 10 s, reads `agentmode status --json`
# and offers On/Off. Copy it into your SwiftBar plugin folder and make it executable.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

spanish=false
first_language="$(defaults read -g AppleLanguages 2> /dev/null | sed -n 2p | tr -d ' ",')"
[[ "${first_language:l}" == es* ]] && spanish=true
t() { $spanish && print -r -- "$2" || print -r -- "$1"; }

bin="$(command -v agentmode)" || {
    print "AM ? | sfimage=questionmark.circle"
    print -- "---"
    print "$(t 'agentmode is not installed' 'agentmode no está instalado') | href=https://github.com/ULookLookMe/agent-mode"
    exit 0
}

json="$("$bin" status --json 2> /dev/null)" || {
    print "AM ! | sfimage=exclamationmark.triangle"
    print -- "---"
    print "$(t 'agentmode status failed' 'agentmode status falló')"
    exit 0
}

field() { plutil -extract "$1" raw -o - - <<< "$json" 2> /dev/null; }
mode="$(field mode)"
intent="$(field intent)"
daemon="$(field daemonRunning)"
heat="$(field heatProtection)"
battery="$(field batteryMaxCelsius)"
chip="$(field chipAverageCelsius)"
human() {
    case "$1" in
        noInternet) t 'no internet' 'sin internet' ;;
        thermal) t 'heat' 'calor' ;;
        lowBattery) t 'low battery' 'batería baja' ;;
        sensorsUnavailable) t 'sensors unreadable' 'sensores ilegibles' ;;
        *) print -r -- "$1" ;;
    esac
}
reasons=""
for reason in $(plutil -extract pauseReasons json -o - - <<< "$json" 2> /dev/null | tr -d '[]" ' | tr ',' ' '); do
    reasons+="${reasons:+, }$(human "$reason")"
done

case "$mode" in
    active) print "AM | sfimage=cup.and.saucer.fill" ;;
    paused) print "AM ‖ | sfimage=pause.circle" ;;
    *) print "AM · | sfimage=moon.zzz" ;;
esac
print -- "---"
case "$mode" in
    active) print "$(t 'Agent mode: on' 'Modo agente: activo')" ;;
    paused) print "$(t 'Agent mode: paused' 'Modo agente: en pausa') (${reasons:-$(t 'waiting for a full wake' 'esperando un despertar completo')})" ;;
    *) print "$(t 'Agent mode: off' 'Modo agente: apagado')" ;;
esac
if [[ "$intent" == on ]]; then
    print "$(t 'Turn off' 'Apagar') | bash=$bin param1=off terminal=false refresh=true"
else
    print "$(t 'Turn on' 'Activar') | bash=$bin param1=on terminal=false refresh=true"
fi
print -- "---"
print "$(t 'Heat protection' 'Protección por calor'): $heat"
[[ -n "$battery" ]] && printf "%s: %.1f °C\n" "$(t 'Battery' 'Batería')" "$battery"
[[ -n "$chip" ]] && printf "%s: %.1f °C\n" "$(t 'Chip' 'Chip')" "$chip"
[[ "$daemon" == true ]] || print "$(t 'Background process: not running' 'Proceso residente: no corre') | color=red"
for i in {0..9}; do
    warning="$(field "warnings.$i")" || break
    [[ -n "$warning" ]] || break
    print -r -- "⚠︎ $warning | color=red"
done
print -- "---"
print "$(t 'Open log' 'Abrir registro') | bash=/usr/bin/open param1=-a param2=Console param3=$HOME/Library/Logs/agentmode.log terminal=false"
print "agentmode on GitHub | href=https://github.com/ULookLookMe/agent-mode"
