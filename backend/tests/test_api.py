import base64
import asyncio
import json
from datetime import UTC, datetime
from io import BytesIO

from fastapi.testclient import TestClient
from PIL import Image, ImageDraw

from app import main as main_module
from app.account_store import AccountStore
from app.main import app, fashion_news_service, weather_style_service
from app.schemas import (
    FashionNewsPost,
    FashionNewsResponse,
    FashionWeatherTip,
    NewsSourceStatus,
    WeatherCurrent,
    WeatherDay,
    WeatherHomeResponse,
)


client = TestClient(app)


def test_health() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert response.json()["version"] == "1.7.0"
    assert response.json()["service"] == "seamly"


def test_shop_catalog_keeps_only_exact_source_linked_images(monkeypatch) -> None:
    catalog = {
        "items": [
            {
                "id": "lazada-123",
                "title": "Linen wrap midi dress",
                "category": "Dresses",
                "marketplace": "Lazada",
                "seller": "Source seller",
                "product_url": "https://www.lazada.com.ph/products/dress-i123.html",
                "image_url": "https://my-live-02.slatic.net/p/dress.jpg",
                "image_source_url": "https://my-live-02.slatic.net/p/dress.jpg",
                "price_label": "₱1,290",
                "sizes": ["S", "M", "L"],
                "color_seasons": ["Autumn"],
            },
            {
                "id": "mismatched-image",
                "title": "Untrusted source mismatch",
                "category": "Tops",
                "marketplace": "Shopee",
                "product_url": "https://shopee.ph/item-i.1.2",
                "image_url": "https://example.com/unrelated.jpg",
                "image_source_url": "https://example.com/unrelated.jpg",
            },
        ]
    }
    monkeypatch.setenv("FASHIONTECH_SHOP_CATALOG_JSON", json.dumps(catalog))
    monkeypatch.delenv("FASHIONTECH_SHOP_CATALOG_URL", raising=False)

    response = client.get("/v1/shop/products")

    assert response.status_code == 200
    payload = response.json()
    assert payload["catalog_mode"] == "source_feed"
    assert [item["id"] for item in payload["items"]] == ["lazada-123"]
    assert payload["items"][0]["image_url"] == payload["items"][0]["image_source_url"]
    assert next(source for source in payload["sources"] if source["name"] == "Lazada")[
        "connected"
    ] is True
    assert "invalid or duplicate record" in payload["disclosure"]


def test_shop_catalog_fails_closed_without_an_approved_feed(monkeypatch) -> None:
    monkeypatch.delenv("FASHIONTECH_SHOP_CATALOG_JSON", raising=False)
    monkeypatch.delenv("FASHIONTECH_SHOP_CATALOG_URL", raising=False)
    monkeypatch.delenv("FASHIONTECH_SHOP_CATALOG_TOKEN", raising=False)

    response = client.get("/v1/shop/products")

    assert response.status_code == 200
    payload = response.json()
    assert payload["catalog_mode"] == "setup_required"
    assert payload["items"] == []
    assert all(source["connected"] is False for source in payload["sources"])


def test_account_registration_login_and_measurement_history(
    monkeypatch, tmp_path
) -> None:
    store = AccountStore(tmp_path / "accounts.db")
    monkeypatch.setattr(main_module, "account_store", store)
    registration = client.post(
        "/v1/auth/register",
        json={
            "name": "Style Tester",
            "email": "style@example.com",
            "password": "fashion123",
            "height_cm": 165,
            "location": "Manila",
        },
    )
    assert registration.status_code == 201
    registered = registration.json()
    assert registered["is_new_account"] is True
    assert registered["profile"]["height_cm"] == 165
    token = registered["token"]

    measurements = {
        "height": 165,
        "neck": 35,
        "shoulder": 40,
        "chest": 94,
        "underbust": 85,
        "waist": 77,
        "high_hip": 96,
        "hip": 103,
        "sleeve": 59,
        "wrist": 16,
        "inseam": 76,
    }
    saved = client.put(
        "/v1/account/measurements",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "measurements": measurements,
            "size_label": "L",
            "scan_confidence": 0.82,
        },
    )
    assert saved.status_code == 200
    assert saved.json()["latest_measurements"]["waist"] == 77

    login = client.post(
        "/v1/auth/login",
        json={"email": "STYLE@example.com", "password": "fashion123"},
    )
    assert login.status_code == 200
    body = login.json()
    assert body["is_new_account"] is False
    assert body["profile"]["size_label"] == "L"
    assert body["profile"]["latest_measurements"]["hip"] == 103


def test_account_rejects_duplicate_email_and_wrong_password(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setattr(main_module, "account_store", AccountStore(tmp_path / "accounts.db"))
    payload = {
        "name": "Style Tester",
        "email": "style@example.com",
        "password": "fashion123",
        "height_cm": 165,
    }
    assert client.post("/v1/auth/register", json=payload).status_code == 201
    assert client.post("/v1/auth/register", json=payload).status_code == 409
    response = client.post(
        "/v1/auth/login",
        json={"email": payload["email"], "password": "wrongpass"},
    )
    assert response.status_code == 401


def test_news_uses_open_graph_image_and_removes_duplicates() -> None:
    markup = (
        '<html><head><meta property="og:image" '
        'content="/images/story-look.jpg"></head></html>'
    )
    assert fashion_news_service._open_graph_image(
        markup, "https://publisher.example/fashion/story"
    ) == "https://publisher.example/images/story-look.jpg"

    now = datetime.now(UTC)
    posts = [
        FashionNewsPost(
            id=str(index),
            title=f"Story {index}",
            summary="Summary",
            url=f"https://publisher.example/{index}",
            image_url="https://publisher.example/images/same.jpg",
            publisher="Publisher",
            platform="Publisher RSS",
            category="all",
            published_at=now,
            like_count=0,
            comment_count=0,
        )
        for index in range(2)
    ]
    enriched = asyncio.run(
        fashion_news_service._enrich_article_images(None, posts)  # type: ignore[arg-type]
    )
    assert enriched[0].image_url is not None
    assert enriched[1].image_url is None


def test_fashion_news_feed_supports_style_categories(monkeypatch) -> None:
    async def fake_fetch(category: str, limit: int) -> FashionNewsResponse:
        return FashionNewsResponse(
            category=category,
            fetched_at=datetime.now(UTC),
            items=[
                FashionNewsPost(
                    id="story-1",
                    title="A Y2K fashion update",
                    summary="A category-specific story.",
                    url="https://example.com/story",
                    publisher="Example Fashion",
                    platform="Google News",
                    category=category,
                    published_at=datetime.now(UTC),
                    like_count=120,
                    comment_count=14,
                )
            ],
            sources=[
                NewsSourceStatus(
                    name="Google News",
                    connected=True,
                    note="Live RSS stories",
                )
            ],
        )

    monkeypatch.setattr(fashion_news_service, "fetch", fake_fetch)
    response = client.get("/v1/news/feed?category=y2k&limit=8")

    assert response.status_code == 200
    body = response.json()
    assert body["category"] == "y2k"
    assert body["items"][0]["category"] == "y2k"
    assert body["sources"][0]["connected"] is True


def test_fashion_news_feed_rejects_unknown_category() -> None:
    response = client.get("/v1/news/feed?category=unknown")
    assert response.status_code == 422


def test_home_weather_returns_current_tomorrow_and_fashion(monkeypatch) -> None:
    async def fake_weather(
        city: str,
        size_label: str | None = None,
        color_season: str | None = None,
    ) -> WeatherHomeResponse:
        return WeatherHomeResponse(
            location=city,
            region="Metro Manila",
            country="Philippines",
            timezone="Asia/Manila",
            updated_at=datetime.now(UTC),
            current=WeatherCurrent(
                temperature_c=30,
                apparent_temperature_c=35,
                humidity_percent=74,
                wind_kmh=12,
                weather_code=2,
                condition="Partly cloudy",
                is_day=True,
            ),
            tomorrow=WeatherDay(
                date="2026-09-04",
                temperature_max_c=31,
                temperature_min_c=25,
                apparent_temperature_max_c=36,
                precipitation_probability=58,
                uv_index_max=7.2,
                weather_code=80,
                condition="Rain showers",
            ),
            fashion=[
                FashionWeatherTip(
                    kind="outfit",
                    title="Airy warm-weather layers",
                    reason=f"Forecast matched for size {size_label} and {color_season}.",
                )
            ],
            source="Open-Meteo forecast",
        )

    monkeypatch.setattr(weather_style_service, "fetch", fake_weather)
    response = client.get(
        "/v1/weather/home?city=Manila&size_label=M&color_season=Autumn"
    )

    assert response.status_code == 200
    body = response.json()
    assert body["current"]["condition"] == "Partly cloudy"
    assert body["tomorrow"]["condition"] == "Rain showers"
    assert body["fashion"][0]["kind"] == "outfit"


def test_geocode_prefers_philippine_result_over_foreign_namesakes() -> None:
    from app.weather_service import WeatherStyleService

    results = [
        {"name": "Kalibo", "country": "Ivory Coast", "country_code": "CI", "population": 347},
        {"name": "Kalibo", "country": "Philippines", "country_code": "PH", "population": 42749},
        {"name": "Kalinago", "country": "Nepal", "country_code": "NP"},
    ]
    picked = WeatherStyleService._pick_geocode_result(
        results, name="Kalibo", hint=None, query="Kalibo"
    )
    assert picked["country_code"] == "PH"


def test_geocode_country_hint_overrides_default_bias() -> None:
    from app.weather_service import WeatherStyleService

    results = [
        {"name": "Paris", "country": "Philippines", "country_code": "PH"},
        {"name": "Paris", "country": "France", "country_code": "FR", "population": 2100000},
    ]
    picked = WeatherStyleService._pick_geocode_result(
        results, name="Paris", hint="france", query="Paris, France"
    )
    assert picked["country_code"] == "FR"


def test_geocode_hint_with_no_match_raises_clear_error() -> None:
    from app.weather_service import WeatherStyleService, WeatherServiceError

    results = [{"name": "Manila", "country": "Philippines", "country_code": "PH"}]
    try:
        WeatherStyleService._pick_geocode_result(
            results, name="Manila", hint="mars", query="Manila, Mars"
        )
    except WeatherServiceError as error:
        assert 'No weather location matched "Manila, Mars"' in str(error)
    else:
        raise AssertionError("expected WeatherServiceError for unmatched hint")


def test_geocode_split_city_query_parses_comma_hint() -> None:
    from app.weather_service import WeatherStyleService

    assert WeatherStyleService._split_city_query("Aklan, Philippines") == (
        "Aklan",
        "Philippines",
    )
    assert WeatherStyleService._split_city_query("Aklan") == ("Aklan", None)
    assert WeatherStyleService._split_city_query("  Kalibo , PH ") == ("Kalibo", "PH")


def test_province_alias_routes_aklan_to_kalibo() -> None:
    from app.weather_service import WeatherStyleService

    assert WeatherStyleService._province_seat("Aklan", None) == ("Kalibo", "Aklan")
    assert WeatherStyleService._province_seat("AKLAN", "Philippines") == (
        "Kalibo",
        "Aklan",
    )
    assert WeatherStyleService._province_seat("Aklan", "Nepal") is None
    assert WeatherStyleService._province_seat("Manila", None) is None


def test_city_attempts_try_alias_before_original_query() -> None:
    from app.weather_service import WeatherStyleService

    assert WeatherStyleService._city_attempts("Aklan") == [
        ("Kalibo", "Philippines", "Aklan"),
        ("Aklan", None, None),
    ]
    assert WeatherStyleService._city_attempts("Manila") == [("Manila", None, None)]
    assert WeatherStyleService._city_attempts("Ilocos Norte") == [
        ("Laoag", "Philippines", "Ilocos Norte"),
        ("Ilocos Norte", None, None),
    ]


def test_city_attempts_disambiguate_known_ph_namesakes() -> None:
    from app.weather_service import WeatherStyleService

    assert WeatherStyleService._city_attempts("Baguio") == [
        ("Baguio", None, "Benguet"),
        ("Baguio", None, None),
    ]
    assert WeatherStyleService._city_attempts("Kalibo") == [
        ("Kalibo", None, "Aklan"),
        ("Kalibo", None, None),
    ]
    assert WeatherStyleService._city_attempts("Baguio, France") == [
        ("Baguio", "France", None)
    ]
    assert WeatherStyleService._city_attempts("Lipa") == [
        ("Lipa City", "Philippines", "Batangas")
    ]


def test_search_variants_retry_without_city_suffix() -> None:
    from app.weather_service import WeatherStyleService

    assert WeatherStyleService._search_variants("Masbate City") == [
        "Masbate City",
        "masbate",
    ]
    assert WeatherStyleService._search_variants("Manila") == ["Manila"]


def test_geocode_pick_uses_region_hint_for_explicit_subdivision() -> None:
    from app.weather_service import WeatherStyleService

    results = [
        {
            "name": "Roxas",
            "country": "Philippines",
            "country_code": "PH",
            "admin1": "Cagayan Valley",
            "admin2": "Province of Isabela",
            "population": 16618,
        },
        {
            "name": "Roxas",
            "country": "Philippines",
            "country_code": "PH",
            "admin1": "Mimaropa",
            "admin2": "Province of Palawan",
            "population": 15242,
        },
    ]
    picked = WeatherStyleService._pick_geocode_result(
        results,
        name="Roxas",
        hint="Palawan",
        query="Roxas, Palawan",
    )
    assert picked["admin2"] == "Province of Palawan"


def test_geocode_pick_prefers_expected_province_over_bigger_namesake() -> None:
    from app.weather_service import WeatherStyleService

    results = [
        {
            "name": "Kalibo",
            "country": "Philippines",
            "country_code": "PH",
            "admin1": "Soccsksargen",
            "admin2": "Province of South Cotabato",
        },
        {
            "name": "Kalibo Town",
            "country": "Philippines",
            "country_code": "PH",
            "admin1": "Western Visayas",
            "admin2": "Province of Aklan",
            "population": 89127,
        },
    ]
    picked = WeatherStyleService._pick_geocode_result(
        results,
        name="Kalibo",
        hint="Philippines",
        query="Aklan",
        province="Aklan",
    )
    assert picked["admin2"] == "Province of Aklan"


def test_fashion_tips_change_with_weather_conditions() -> None:
    from app.weather_service import WeatherStyleService
    from app.schemas import WeatherDay

    service = WeatherStyleService()
    tomorrow = WeatherDay(
        date="2026-09-25",
        temperature_max_c=31,
        temperature_min_c=25,
        apparent_temperature_max_c=36,
        precipitation_probability=10,
        uv_index_max=7.2,
        weather_code=1,
        condition="Mainly clear",
    )
    hot_dry = service._fashion_tips(
        temperature=31,
        apparent=36,
        humidity=55,
        condition="Clear sky",
        code=0,
        tomorrow=tomorrow,
        wind=8,
        size_label=None,
        color_season=None,
    )
    hot_wet = service._fashion_tips(
        temperature=31,
        apparent=36,
        humidity=88,
        condition="Rain",
        code=61,
        tomorrow=tomorrow,
        wind=8,
        size_label=None,
        color_season=None,
    )
    mild = service._fashion_tips(
        temperature=22,
        apparent=21,
        humidity=60,
        condition="Partly cloudy",
        code=2,
        tomorrow=tomorrow,
        wind=8,
        size_label=None,
        color_season=None,
    )
    cold = service._fashion_tips(
        temperature=2,
        apparent=-2,
        humidity=70,
        condition="Snow",
        code=71,
        tomorrow=tomorrow,
        wind=18,
        size_label=None,
        color_season=None,
    )

    titles = [tips[0].title for tips in (hot_dry, hot_wet, mild, cold)]
    assert len(set(titles)) == 4, titles
    assert titles[0] == "Ultralight heat-ready layers"
    assert titles[1].startswith("Rain-ready:")
    assert titles[3] == "Insulated cold-weather layers"
    assert "feels like" in cold[0].reason or "feels like" in str(cold[0].reason).lower()


def test_weather_home_response_echoes_requested_city(monkeypatch) -> None:
    async def fake_weather(
        city: str,
        size_label: str | None = None,
        color_season: str | None = None,
    ) -> WeatherHomeResponse:
        return WeatherHomeResponse(
            requested_city=city,
            location="Aklan",
            region="Aklan",
            country="Philippines",
            timezone="Asia/Manila",
            updated_at=datetime.now(UTC),
            current=WeatherCurrent(
                temperature_c=24,
                apparent_temperature_c=27,
                humidity_percent=82,
                wind_kmh=15,
                weather_code=61,
                condition="Rain",
                is_day=True,
            ),
            tomorrow=WeatherDay(
                date="2026-09-26",
                temperature_max_c=29,
                temperature_min_c=23,
                apparent_temperature_max_c=32,
                precipitation_probability=70,
                uv_index_max=5.0,
                weather_code=80,
                condition="Rain showers",
            ),
            fashion=[
                FashionWeatherTip(
                    kind="outfit",
                    title="Rain-ready light everyday separates",
                    reason="Feels like 27°C with 82% humidity.",
                )
            ],
            source="Open-Meteo forecast",
        )

    monkeypatch.setattr(weather_style_service, "fetch", fake_weather)
    response = client.get("/v1/weather/home?city=Aklan")

    assert response.status_code == 200
    body = response.json()
    assert body["requested_city"] == "Aklan"
    assert body["fashion"][0]["title"].startswith("Rain-ready")


def _wttr_payload() -> dict:
    return {
        "current_condition": [
            {
                "temp_C": "24",
                "FeelsLikeC": "28",
                "humidity": "90",
                "windspeedKmph": "12",
                "uvIndex": "3",
                "weatherDesc": [{"value": "Patchy rain nearby"}],
            }
        ],
        "weather": [
            {
                "date": "2026-09-25",
                "maxtempC": "30",
                "mintempC": "23",
                "hourly": [
                    {
                        "time": "1200",
                        "weatherDesc": [{"value": "Patchy rain nearby"}],
                        "chanceofrain": "70",
                        "uvIndex": "6",
                    }
                ],
            },
            {
                "date": "2026-09-26",
                "maxtempC": "29",
                "mintempC": "22",
                "hourly": [
                    {
                        "time": "1200",
                        "weatherDesc": [{"value": "Light rain shower"}],
                        "chanceofrain": "60",
                        "uvIndex": "5",
                    }
                ],
            },
        ],
        "nearest_area": [
            {
                "areaName": [{"value": "Other Town"}],
                "region": [{"value": "Other Region"}],
                "country": [{"value": "Otherland"}],
            }
        ],
        "timezone": {"name": "Asia/Manila"},
    }


class _FakeWttrResponse:
    def __init__(self, payload: dict) -> None:
        self.status_code = 200
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return self._payload


class _FakeWttrClient:
    def __init__(self, payload: dict) -> None:
        self._payload = payload
        self.requested: list[str] = []

    async def get(self, url: str, params: dict | None = None) -> _FakeWttrResponse:
        self.requested.append(url)
        return _FakeWttrResponse(self._payload)


def test_wttr_fallback_uses_geocoded_coordinates_and_names() -> None:
    import asyncio

    from app.weather_service import WeatherStyleService

    fake_client = _FakeWttrClient(_wttr_payload())
    response = asyncio.run(
        WeatherStyleService()._fetch_wttr_fallback(
            fake_client,  # type: ignore[arg-type]
            city="Kalibo",
            location={
                "name": "Kalibo Town",
                "latitude": 11.70611,
                "longitude": 120.36444,
                "admin1": "Western Visayas",
                "country": "Philippines",
            },
            size_label=None,
            color_season=None,
        )
    )

    assert fake_client.requested == ["https://wttr.in/11.70611,120.36444"]
    assert response.location == "Kalibo Town"
    assert response.region == "Western Visayas"
    assert response.country == "Philippines"
    assert response.requested_city == "Kalibo"
    assert response.source == "wttr.in fallback"
    assert response.fashion


def test_wttr_fallback_without_geocode_queries_raw_city() -> None:
    import asyncio

    from app.weather_service import WeatherStyleService

    fake_client = _FakeWttrClient(_wttr_payload())
    response = asyncio.run(
        WeatherStyleService()._fetch_wttr_fallback(
            fake_client,  # type: ignore[arg-type]
            city="Vigan",
            location=None,
            size_label=None,
            color_season=None,
        )
    )

    assert fake_client.requested == ["https://wttr.in/Vigan"]
    assert response.location == "Other Town"
    assert response.region == "Other Region"
    assert response.country == "Otherland"
    assert response.requested_city == "Vigan"
    assert response.source == "wttr.in fallback"


def test_local_development_origin_is_allowed() -> None:
    response = client.options(
        "/v1/size/recommend",
        headers={
            "Origin": "http://127.0.0.1:8765",
            "Access-Control-Request-Method": "POST",
        },
    )
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://127.0.0.1:8765"


def test_hosted_application_origin_is_allowed() -> None:
    origin = "https://stylorista-ai.jadesalvador3257.chatgpt.site"
    response = client.options(
        "/v1/size/recommend",
        headers={
            "Origin": origin,
            "Access-Control-Request-Method": "POST",
        },
    )
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == origin


def test_size_recommendation_is_bounded() -> None:
    response = client.post(
        "/v1/size/recommend",
        json={
            "measurements": {
                "height": 165,
                "neck": 35,
                "shoulder": 40,
                "chest": 94,
                "underbust": 85,
                "waist": 77,
                "high_hip": 96,
                "hip": 103,
                "sleeve": 59,
                "wrist": 16,
                "inseam": 76,
            },
            "fit_preference": "regular",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["recommended_size"] in {"2XS", "XS", "S", "M", "L", "XL", "2XL", "3XL", "4XL"}
    assert 0 <= body["confidence"] <= 1
    assert len(body["alternatives"]) == 3


def test_invalid_measurement_is_rejected() -> None:
    response = client.post(
        "/v1/size/recommend",
        json={"measurements": {"height": 20, "chest": 94, "waist": 77, "hip": 103}},
    )
    assert response.status_code == 422


def _portrait_photo() -> str:
    image = Image.new("RGB", (240, 480), "#D9D7D2")
    draw = ImageDraw.Draw(image)
    draw.ellipse((68, 48, 172, 180), fill="#C68670")
    draw.rectangle((104, 168, 136, 218), fill="#C68670")
    draw.polygon([(48, 215), (192, 215), (218, 470), (22, 470)], fill="#39495A")
    buffer = BytesIO()
    image.save(buffer, format="JPEG", quality=92)
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def test_profile_photo_returns_accessories_and_color_direction() -> None:
    response = client.post(
        "/v1/profile/analyze",
        json={
            "image_base64": _portrait_photo(),
            "consent_confirmed": True,
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["color_season"] in {"Spring", "Summer", "Autumn", "Winter"}
    assert len(body["accessories"]) == 4
    assert len(body["palette"]) >= 4
    assert 0 <= body["confidence"] <= 1
    assert 0 <= body["lighting_quality"] <= 1
    assert body["quality_warnings"]
    assert body["model_version"] == "appearance-color-calibrated-demo-0.2.0"
    assert "not identity" in body["disclaimer"]


def test_profile_color_analysis_rejects_dark_photo() -> None:
    image = Image.new("RGB", (240, 480), "#151515")
    buffer = BytesIO()
    image.save(buffer, format="JPEG", quality=90)
    response = client.post(
        "/v1/profile/analyze",
        json={
            "image_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
            "consent_confirmed": True,
        },
    )

    assert response.status_code == 422
    assert "too dark" in response.json()["detail"]


def test_profile_photo_requires_consent() -> None:
    response = client.post(
        "/v1/profile/analyze",
        json={
            "image_base64": _portrait_photo(),
            "consent_confirmed": False,
        },
    )
    assert response.status_code == 422


def test_color_analysis_returns_palette() -> None:
    response = client.post(
        "/v1/color/analyze",
        json={"skin_hex": "#C98F70", "hair_hex": "#3D2A22", "eye_hex": "#65483A"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["season"] in {"Spring", "Summer", "Autumn", "Winter"}
    assert len(body["palette"]) >= 4


def test_tropical_season_uses_wet_dry_cycle() -> None:
    response = client.post(
        "/v1/style/recommend",
        json={
            "climate": "tropical",
            "hemisphere": "northern",
            "month": 8,
            "occasion": "work",
            "style": "classic",
            "color_season": "Autumn",
            "size_label": "M",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["current_season"] == "Wet"
    assert body["pieces"]
    assert body["palette"]
