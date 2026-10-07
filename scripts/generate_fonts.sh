#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fonts="${repo_dir}/shared/nav_ui/assets/fonts/source"
out="${repo_dir}/shared/nav_ui/assets"
latin=" ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,;:!?'-+/()°%"
cjk='建国路东三环中朝阳门外大街进入岛，第二出口已到达目的地前方拥堵缓行畅通偏航重新规划断网恢复直左右转掉头米公里分钟高速辅主道匝隧桥请保持车驶向终点当前路线热点在线离线获取定位无信号等待距下一动作打开手机应用正在建立连接成功选择星湖街手机已断开向前行驶南京大学'

cd "${repo_dir}"
generate() {
  local font="$1" size="$2" symbols="$3" name="$4" file="$5"
  local converter=(npx --yes lv_font_conv@1.5.3)
  if [[ -n "${LV_FONT_CONV:-}" ]]; then
    converter=("${LV_FONT_CONV}")
  fi
  "${converter[@]}" --font "${fonts}/${font}" --size "${size}" \
    --bpp 4 --format lvgl --no-compress --symbols "${symbols}" \
    --lv-font-name "${name}" -o "${out}/${file}"
}

generate Inter-Medium.ttf 16 "${latin}" waymate_a_16_84851 moto_font_inter_medium_16.c
generate Inter-Medium.ttf 20 "${latin}" waymate_a_20_91119 moto_font_inter_medium_20.c
generate Inter-SemiBold.ttf 28 "${latin}" waymate_a_28_40830 moto_font_inter_semibold_28.c
generate Inter-SemiBold.ttf 32 ' ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-./' waymate_a_32_74884 moto_font_inter_semibold_32.c
generate Inter-SemiBold.ttf 36 'NEWSAITG' waymate_a_36_34158 moto_font_inter_semibold_36.c
generate Inter-SemiBold.ttf 56 '0123456789-.°' waymate_a_56_90603 moto_font_inter_semibold_56.c
generate Inter-SemiBold.ttf 96 '0123456789-.' waymate_a_96_58825 moto_font_inter_semibold_96.c
generate NotoSansSC-Medium.ttf 16 "${cjk}" waymate_noto_16_75639 moto_font_cjk_16.c
generate NotoSansSC-Medium.ttf 28 "${cjk}" waymate_noto_28_75038 moto_font_cjk_28.c
