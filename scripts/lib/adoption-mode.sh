#!/bin/sh
# Sentinel Shield — the adoption mode vocabulary, in one place.
#
# The engine already had this vocabulary and already treated an unknown mode as a configuration
# error rather than a weaker custom state. It was read ad hoc wherever it was needed. Two criteria
# scope behaviour by mode -- a digest-pinned scanner container "for gated use" (#103) and a
# database fail/warn policy "by mode" (#137) -- and a trust boundary answered by several subtly
# different implementations is not a trust boundary. Both now read this.
#
# GATED means the mode's verdict gates a release. strict and regulated do; report-only and
# baseline do not. That distinction is the whole reason the criteria say "for gated use" and
# "by mode" rather than "always".

AM_MODES_ALL='report-only baseline strict regulated'
AM_MODES_GATED='strict regulated'

am_mode() { printf '%s' "${SENTINEL_SHIELD_MODE:-baseline}"; }

am_mode_valid() { # am_mode_valid [mode]
	_am_m=${1:-$(am_mode)}
	for _am_c in $AM_MODES_ALL; do [ "$_am_c" = "$_am_m" ] && return 0; done
	return 1
}

am_gated() { # 0 when the active mode gates a release
	_am_g=$(am_mode)
	for _am_c in $AM_MODES_GATED; do [ "$_am_c" = "$_am_g" ] && return 0; done
	return 1
}
