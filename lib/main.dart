import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:geolocator/geolocator.dart';

void main() => runApp(
  const MaterialApp(debugShowCheckedModeBanner: false, home: SiestaEliteApp()),
);

enum ShopStatus { open, closingSoon, closed }

class SiestaEliteApp extends StatefulWidget {
  const SiestaEliteApp({super.key});
  @override
  State<SiestaEliteApp> createState() => _SiEliteAppState();
}

class _SiEliteAppState extends State<SiestaEliteApp> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  List _allShops = [];
  String? _tappedShopId;
  bool _loading = false;
  bool _mapReady = false;
  LatLng _currentCenter = const LatLng(40.4168, -3.7038);
  Timer? _moveDebounce;

  @override
  void initState() {
    super.initState();
    _initGps();
  }

  Future<void> _initGps() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(
        timeLimit: const Duration(seconds: 3),
      );
      setState(() {
        _currentCenter = LatLng(pos.latitude, pos.longitude);
      });
      if (_mapReady) {
        _mapController.move(_currentCenter, 15.0);
        _fetchNearby(_currentCenter);
      }
    } catch (e) {
      print("GPS skipped");
    }
  }

  Future<void> _fetchAddressForShop(Map shop) async {
    if (shop['tags']['addr:street'] != null) return;
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse?lat=${shop['lat']}&lon=${shop['lon']}&format=json',
    );
    try {
      final res = await http.get(
        url,
        headers: {'User-Agent': 'SiestaWatcher_Dominik'},
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        setState(() {
          shop['tags']['addr:street'] =
              data['address']['road'] ?? "Unknown Street";
          shop['tags']['addr:housenumber'] =
              data['address']['house_number'] ?? "";
        });
      }
    } catch (e) {
      print("Address error");
    }
  }

  ShopStatus getStatus(String? hours) {
    if (hours == null || hours.isEmpty) return ShopStatus.open;
    final now = DateTime.now();
    final currentTime = now.hour * 100 + now.minute;
    final regExp = RegExp(r"(\d{2}):(\d{2})-(\d{2}):(\d{2})");
    final matches = regExp.allMatches(hours);
    if (matches.isEmpty) return ShopStatus.open;
    for (var m in matches) {
      final start = int.parse(m.group(1)! + m.group(2)!);
      final end = int.parse(m.group(3)! + m.group(4)!);
      if (currentTime >= start && currentTime <= end) {
        final remaining =
            (int.parse(m.group(3)!) * 60 + int.parse(m.group(4)!)) -
            (now.hour * 60 + now.minute);
        return (remaining <= 60 && remaining > 0)
            ? ShopStatus.closingSoon
            : ShopStatus.open;
      }
    }
    return ShopStatus.closed;
  }

  Color getStatusColor(ShopStatus status) {
    switch (status) {
      case ShopStatus.open:
        return Colors.green;
      case ShopStatus.closingSoon:
        return Colors.orange;
      case ShopStatus.closed:
        return Colors.red;
    }
  }

  Future<void> _fetchNearby(LatLng pos) async {
    if (_mapController.camera.zoom < 11) return;
    setState(() {
      _loading = true;
      _allShops = [];
      _tappedShopId = null;
    });
    final q =
        '[out:json][timeout:25];node(around:2000,${pos.latitude},${pos.longitude})["shop"];out body;';
    try {
      final res = await http.get(
        Uri.parse('https://overpass-api.de/api/interpreter?data=$q'),
      );
      if (res.statusCode == 200) {
        setState(() {
          _allShops = json.decode(res.body)['elements'];
          _loading = false;
        });
      }
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // --- SORTING LOGIC: Draw selected shop LAST so it's on top ---
    List sortedShops = List.from(_allShops);
    if (_tappedShopId != null) {
      int selectedIdx = sortedShops.indexWhere(
        (s) => s['id'].toString() == _tappedShopId,
      );
      if (selectedIdx != -1) {
        final selectedShop = sortedShops.removeAt(selectedIdx);
        sortedShops.add(selectedShop); // Move to end of list
      }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.orange,
        title: TextField(
          controller: _searchController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "Search Spain...",
            border: InputBorder.none,
            hintStyle: TextStyle(color: Colors.white70),
          ),
          onSubmitted: (val) async {
            final res = await http.get(
              Uri.parse(
                'https://nominatim.openstreetmap.org/search?q=$val,Spain&format=json&limit=1',
              ),
            );
            if (res.statusCode == 200 && json.decode(res.body).isNotEmpty) {
              final loc = json.decode(res.body)[0];
              final p = LatLng(
                double.parse(loc['lat']),
                double.parse(loc['lon']),
              );
              _mapController.move(p, 16);
              _fetchNearby(p);
            }
          },
        ),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentCenter,
              initialZoom: 6.0,
              onMapReady: () => setState(() => _mapReady = true),
              onPositionChanged: (p, g) {
                if (g) {
                  _moveDebounce?.cancel();
                  _moveDebounce = Timer(
                    const Duration(milliseconds: 700),
                    () => _fetchNearby(p.center!),
                  );
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              ),
              MarkerLayer(
                markers: sortedShops.map((s) {
                  final bool isSelected = _tappedShopId == s['id'].toString();
                  final status = getStatus(s['tags']['opening_hours']);
                  final color = getStatusColor(status);

                  return Marker(
                    point: LatLng(s['lat'], s['lon']),
                    // We give the bubble more space so it doesn't clip
                    width: isSelected ? 240 : 40,
                    height: isSelected ? 120 : 40,
                    alignment: isSelected
                        ? Alignment.topCenter
                        : Alignment.center,
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _tappedShopId = s['id'].toString());
                        _fetchAddressForShop(s);
                      },
                      child: isSelected
                          ? _buildInfoBubble(s, color)
                          : Icon(Icons.location_on, color: color, size: 35),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          if (_loading)
            const Positioned(
              top: 10,
              left: 10,
              child: CircularProgressIndicator(color: Colors.orange),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoBubble(Map s, Color statusColor) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 3)),
        ],
        border: Border.all(color: statusColor, width: 2.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  s['tags']['name'] ?? "Shop",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.close, size: 20, color: Colors.grey),
                onPressed: () => setState(() => _tappedShopId = null),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            "${s['tags']['addr:street'] ?? 'Locating...'} ${s['tags']['addr:housenumber'] ?? ''}",
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
          const Divider(height: 12),
          Text(
            s['tags']['opening_hours'] ?? "Check door for hours",
            style: TextStyle(
              fontSize: 10,
              color: statusColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
