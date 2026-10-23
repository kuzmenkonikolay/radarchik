#ifndef RADARCHIK_CPCAP_SHIM_H
#define RADARCHIK_CPCAP_SHIM_H

#include <pcap/pcap.h>

/// Apple DLT_PKTAP: в `pcap/dlt.h` он объявлен как DLT_USER2 (149) только под `#ifdef __APPLE__`
/// с особыми условиями, поэтому держим число здесь. Пакет с таким DLT начинается
/// с заголовка pktap (pid и имя процесса), раскладка — в `PacketParse.swift`.
static const int RADARCHIK_DLT_PKTAP = 149;

/// Apple-овские вызовы libpcap, которых нет в заголовке SDK, но которые есть в
/// `libpcap.A.dylib` (ими пользуется системный tcpdump). Без `pcap_set_want_pktap`
/// до активации pktap-устройство не предлагает DLT_PKTAP: «PKTAP is not one of the
/// DLTs supported by this device» (проверено 2026-10-22).
int pcap_set_want_pktap(pcap_t *p, int want);

#endif
