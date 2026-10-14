from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

from .avatar import normalize_avatar


class Measurements(BaseModel):
    height: float = Field(ge=120, le=230, description="Height in centimetres")
    neck: float | None = Field(default=None, ge=20, le=70)
    shoulder: float | None = Field(default=None, ge=25, le=75)
    chest: float = Field(ge=55, le=190)
    underbust: float | None = Field(default=None, ge=50, le=170)
    waist: float = Field(ge=45, le=190)
    high_hip: float | None = Field(default=None, ge=55, le=200)
    hip: float = Field(ge=60, le=210)
    sleeve: float | None = Field(default=None, ge=35, le=90)
    wrist: float | None = Field(default=None, ge=10, le=35)
    inseam: float | None = Field(default=None, ge=45, le=110)


class AccountRegisterRequest(BaseModel):
    name: str = Field(min_length=2, max_length=100)
    email: str = Field(min_length=5, max_length=254)
    password: str = Field(min_length=8, max_length=128)
    height_cm: float = Field(ge=120, le=230)
    phone: str | None = Field(default=None, max_length=40)
    location: str | None = Field(default=None, max_length=100)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        normalized = value.strip().lower()
        if "@" not in normalized or "." not in normalized.rsplit("@", 1)[-1]:
            raise ValueError("Enter a valid email address")
        return normalized


class AccountLoginRequest(BaseModel):
    email: str = Field(min_length=5, max_length=254)
    password: str = Field(min_length=8, max_length=128)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        return value.strip().lower()


class AccountGoogleLoginRequest(BaseModel):
    id_token: str = Field(min_length=10, max_length=8000)


class AccountProfile(BaseModel):
    id: str
    name: str
    avatar_base64: str | None = None
    email: str
    phone: str | None = None
    location: str | None = None
    height_cm: float = Field(ge=120, le=230)
    latest_measurements: Measurements | None = None
    size_label: str | None = None
    scan_confidence: float | None = Field(default=None, ge=0, le=1)
    measurements_updated_at: datetime | None = None


class AccountAuthResponse(BaseModel):
    token: str
    is_new_account: bool
    profile: AccountProfile


class AccountProfileUpdateRequest(BaseModel):
    name: str = Field(min_length=2, max_length=100)
    height_cm: float = Field(ge=120, le=230)
    avatar_base64: str | None = Field(default=None, max_length=3_000_000)

    @field_validator("height_cm")
    @classmethod
    def measurement_precision(cls, value: float) -> float:
        return round(value, 1)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        value = value.strip()
        if len(value) < 2:
            raise ValueError("Enter at least two characters for your name.")
        return value

    @field_validator("avatar_base64")
    @classmethod
    def validate_avatar(cls, value: str | None) -> str | None:
        return normalize_avatar(value) if value is not None else None


class SavedMeasurementsRequest(BaseModel):
    measurements: Measurements
    size_label: str | None = Field(default=None, max_length=12)
    scan_confidence: float | None = Field(default=None, ge=0, le=1)


class SizeRequest(BaseModel):
    measurements: Measurements
    fit_preference: Literal["close", "regular", "relaxed"] = "regular"


class SizeAlternative(BaseModel):
    label: str
    probability: float


class SizeResponse(BaseModel):
    recommended_size: str
    confidence: float
    alternatives: list[SizeAlternative]
    fit_notes: list[str]
    model_version: str
    disclaimer: str


class BodyScanResponse(BaseModel):
    person_detected: bool
    person_confidence: float = Field(ge=0, le=1)
    measurements: Measurements
    scan_confidence: float = Field(ge=0, le=1)
    image_quality: float = Field(ge=0, le=1)
    measurement_confidence: dict[str, float]
    displayable_measurements: list[str]
    quality_warnings: list[str]
    model_version: str
    validation_status: str
    disclaimer: str


class ColorRequest(BaseModel):
    skin_hex: str
    hair_hex: str
    eye_hex: str

    @field_validator("skin_hex", "hair_hex", "eye_hex")
    @classmethod
    def validate_hex(cls, value: str) -> str:
        normalized = value.strip().lstrip("#").upper()
        if len(normalized) != 6 or any(c not in "0123456789ABCDEF" for c in normalized):
            raise ValueError("Use a six-character hexadecimal color such as C98F70")
        return f"#{normalized}"


class ColorResponse(BaseModel):
    season: str
    confidence: float
    description: str
    palette: list[str]
    neutrals: list[str]
    metals: list[str]
    guidance: list[str]
    model_version: str
    disclaimer: str


class StyleRequest(BaseModel):
    climate: Literal["tropical", "temperate", "cold", "arid"] = "tropical"
    hemisphere: Literal["northern", "southern"] = "northern"
    month: int = Field(ge=1, le=12)
    occasion: Literal["everyday", "work", "event", "travel"] = "everyday"
    style: Literal["minimal", "classic", "street", "romantic"] = "minimal"
    color_season: Literal["Spring", "Summer", "Autumn", "Winter"] = "Autumn"
    size_label: str | None = None


class StyleResponse(BaseModel):
    current_season: str
    title: str
    summary: str
    pieces: list[str]
    fabrics: list[str]
    palette: list[str]
    styling_notes: list[str]
    model_version: str


class OutfitPlanRequest(BaseModel):
    event_text: str = Field(min_length=2, max_length=80)
    city: str = Field(min_length=2, max_length=100)
    event_date: date
    event_time: str | None = Field(default=None, max_length=5)
    style: str | None = Field(default=None, max_length=40)
    climate: Literal["tropical", "temperate", "cold", "arid"] = "tropical"
    hemisphere: Literal["northern", "southern"] = "northern"
    size_label: str | None = Field(default=None, max_length=12)
    color_season: Literal["Spring", "Summer", "Autumn", "Winter"] | None = None
    measurements: Measurements | None = None

    @field_validator("event_text")
    @classmethod
    def clean_event_text(cls, value: str) -> str:
        value = " ".join(value.split())
        if len(value) < 2:
            raise ValueError("Describe your event in at least two characters.")
        return value

    @field_validator("event_time")
    @classmethod
    def validate_event_time(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            datetime.strptime(value.strip(), "%H:%M")
        except ValueError:
            raise ValueError("Use 24-hour HH:MM time such as 16:00")
        return value.strip()


class OutfitPlanWeather(BaseModel):
    temperature_c: float | None = None
    feels_like_c: float | None = None
    condition: str
    rain_probability: int | None = Field(default=None, ge=0, le=100)
    wind_kmh: float | None = Field(default=None, ge=0)
    uv_index_max: float | None = Field(default=None, ge=0)
    is_forecast: bool


class OutfitInspirationImage(BaseModel):
    image_url: str
    photographer: str
    photographer_url: str
    alt: str


class OutfitPlanResponse(BaseModel):
    event_text: str
    occasion: str
    style_used: str
    city: str
    location: str
    event_datetime: str
    timezone: str
    weather: OutfitPlanWeather
    title: str
    summary: str
    pieces: list[str]
    fabrics: list[str]
    palette: list[str]
    styling_notes: list[str]
    fit_notes: list[str] = Field(default_factory=list)
    reasons: list[str]
    confidence: float = Field(ge=0, le=1)
    inspiration_images: list[OutfitInspirationImage] = Field(default_factory=list)
    model_version: str
    disclaimer: str


class FashionNewsPost(BaseModel):
    id: str
    title: str
    summary: str
    url: str
    image_url: str | None = None
    publisher: str
    platform: str
    category: str
    published_at: datetime
    like_count: int = Field(ge=0)
    comment_count: int = Field(ge=0)


class NewsSourceStatus(BaseModel):
    name: str
    connected: bool
    note: str


class FashionNewsResponse(BaseModel):
    category: str
    fetched_at: datetime
    items: list[FashionNewsPost]
    sources: list[NewsSourceStatus]


class ShopProduct(BaseModel):
    id: str = Field(min_length=1, max_length=120)
    title: str = Field(min_length=2, max_length=240)
    category: Literal["Tops", "Bottoms", "Dresses", "Outerwear", "Accessories"]
    marketplace: Literal["Shopee", "Lazada", "Temu"]
    seller: str | None = Field(default=None, max_length=120)
    product_url: str
    image_url: str
    image_source_url: str
    price_label: str | None = Field(default=None, max_length=60)
    sizes: list[str] = Field(default_factory=list, max_length=40)
    color_seasons: list[
        Literal["Spring", "Summer", "Autumn", "Winter"]
    ] = Field(default_factory=list, max_length=4)
    source_updated_at: datetime | None = None


class ShopSourceStatus(BaseModel):
    name: Literal["Shopee", "Lazada", "Temu"]
    connected: bool
    item_count: int = Field(ge=0)
    note: str


class ShopProductsResponse(BaseModel):
    fetched_at: datetime
    items: list[ShopProduct]
    sources: list[ShopSourceStatus]
    catalog_mode: Literal["source_feed", "setup_required"]
    disclosure: str


class AppearanceAnalysisRequest(BaseModel):
    image_base64: str = Field(min_length=32, max_length=18_000_000)
    consent_confirmed: bool

    @field_validator("consent_confirmed")
    @classmethod
    def require_photo_consent(cls, value: bool) -> bool:
        if not value:
            raise ValueError("Photo analysis requires explicit consent")
        return value


class AccessorySuggestion(BaseModel):
    name: str
    reason: str


class AppearanceAnalysisResponse(BaseModel):
    color_season: Literal["Spring", "Summer", "Autumn", "Winter"]
    complexion_direction: str
    sampled_color: str
    confidence: float = Field(ge=0, le=1)
    lighting_quality: float = Field(ge=0, le=1)
    quality_warnings: list[str]
    palette: list[str]
    metals: list[str]
    accessories: list[AccessorySuggestion]
    styling_notes: list[str]
    model_version: str
    disclaimer: str


class WeatherCurrent(BaseModel):
    temperature_c: float
    apparent_temperature_c: float
    humidity_percent: int = Field(ge=0, le=100)
    wind_kmh: float = Field(ge=0)
    weather_code: int
    condition: str
    is_day: bool


class WeatherDay(BaseModel):
    date: str
    temperature_max_c: float
    temperature_min_c: float
    apparent_temperature_max_c: float
    precipitation_probability: int = Field(ge=0, le=100)
    uv_index_max: float = Field(ge=0)
    weather_code: int
    condition: str


class FashionWeatherTip(BaseModel):
    kind: Literal["outfit", "weather", "fit", "color"]
    title: str
    reason: str


class WeatherHomeResponse(BaseModel):
    requested_city: str | None = None
    location: str
    region: str | None = None
    country: str | None = None
    timezone: str
    updated_at: datetime
    current: WeatherCurrent
    tomorrow: WeatherDay
    fashion: list[FashionWeatherTip]
    source: str
