from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Literal

import httpx
from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from .ai_engine import SIZE_CENTRES, SeamlyEngine
from .outfit_images import OutfitImageService, build_inspiration_query
from .account_store import (
    AccountExistsError,
    InvalidCredentialsError,
    StaleMeasurementsError,
    create_account_store,
)
from .google_auth import GoogleAuthError, verify_google_id_token
from .appearance_analysis import AppearanceAnalysisError, AppearanceAnalyzer
from .body_scan import BodyScanError, BodyScanEstimator
from .body_profile import BodyProfileError, BodyProfileEstimator, BodyProfileRequest
from .news_feed import FashionNewsService
from .schemas import (
    AccountAuthResponse,
    AccountGoogleLoginRequest,
    AccountLoginRequest,
    AccountProfile,
    AccountProfileUpdateRequest,
    AccountRegisterRequest,
    BodyScanPreviewRequest,
    BodyScanPreviewResponse,
    BodyScanRequest,
    BodyScanResponse,
    AppearanceAnalysisRequest,
    AppearanceAnalysisResponse,
    ColorRequest,
    ColorResponse,
    FashionNewsResponse,
    OutfitInspirationImage,
    OutfitPlanRequest,
    OutfitPlanResponse,
    OutfitPlanWeather,
    SizeRequest,
    SizeResponse,
    SavedMeasurementsRequest,
    ShopProductsResponse,
    StyleRequest,
    StyleResponse,
    WeatherHomeResponse,
)
from .weather_service import WeatherServiceError, WeatherStyleService
from .shop_catalog import ShopCatalogService


app = FastAPI(
    title="Seamly API",
    description="Privacy-first fashion fit, personal color and seasonal styling MVP.",
    version="1.7.0",
)

configured_origins = [
    origin.strip()
    for origin in os.getenv("CORS_ALLOWED_ORIGINS", "").split(",")
    if origin.strip()
] or ["https://stylorista-ai.jadesalvador3257.chatgpt.site"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=configured_origins,
    allow_origin_regex=r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$",
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT"],
    allow_headers=["*"],
)

engine = SeamlyEngine()
body_scan_estimator = BodyScanEstimator()
body_profile_estimator = BodyProfileEstimator()
appearance_analyzer = AppearanceAnalyzer()
fashion_news_service = FashionNewsService()
weather_style_service = WeatherStyleService()
shop_catalog_service = ShopCatalogService()
account_store = create_account_store()
outfit_image_service = OutfitImageService()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "seamly", "version": app.version}


def _bearer_token(authorization: str | None) -> str:
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(status_code=401, detail="Please sign in to continue.")
    return token.strip()


@app.post("/v1/auth/register", response_model=AccountAuthResponse, status_code=201)
def register_account(request: AccountRegisterRequest) -> AccountAuthResponse:
    try:
        token, profile = account_store.register(
            name=request.name,
            email=request.email,
            password=request.password,
            height_cm=request.height_cm,
            phone=request.phone,
            location=request.location,
        )
    except AccountExistsError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    return AccountAuthResponse(
        token=token,
        is_new_account=True,
        profile=AccountProfile.model_validate(profile),
    )


@app.post("/v1/auth/login", response_model=AccountAuthResponse)
def login_account(request: AccountLoginRequest) -> AccountAuthResponse:
    try:
        token, profile = account_store.login(
            email=request.email,
            password=request.password,
        )
    except InvalidCredentialsError as error:
        raise HTTPException(status_code=401, detail=str(error)) from error
    return AccountAuthResponse(
        token=token,
        is_new_account=False,
        profile=AccountProfile.model_validate(profile),
    )


@app.post("/v1/auth/google", response_model=AccountAuthResponse)
def login_with_google(request: AccountGoogleLoginRequest) -> AccountAuthResponse:
    try:
        claims = verify_google_id_token(request.id_token)
    except GoogleAuthError as error:
        raise HTTPException(status_code=401, detail=str(error)) from error
    try:
        token, profile, is_new = account_store.login_with_google(
            google_sub=claims["sub"],
            email=claims["email"],
            name=claims["name"],
        )
    except AccountExistsError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    return AccountAuthResponse(
        token=token,
        is_new_account=is_new,
        profile=AccountProfile.model_validate(profile),
    )


@app.get("/v1/account/profile", response_model=AccountProfile)
def account_profile(authorization: str | None = Header(default=None)) -> AccountProfile:
    try:
        return AccountProfile.model_validate(
            account_store.profile_for_token(_bearer_token(authorization))
        )
    except InvalidCredentialsError as error:
        raise HTTPException(status_code=401, detail=str(error)) from error


@app.put("/v1/account/measurements", response_model=AccountProfile)
def save_account_measurements(
    request: SavedMeasurementsRequest,
    authorization: str | None = Header(default=None),
) -> AccountProfile:
    try:
        profile = account_store.save_measurements(
            token=_bearer_token(authorization),
            measurements=request.measurements.model_dump(),
            size_label=request.size_label,
            scan_confidence=request.scan_confidence,
        )
    except InvalidCredentialsError as error:
        raise HTTPException(status_code=401, detail=str(error)) from error
    except StaleMeasurementsError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    return AccountProfile.model_validate(profile)


@app.put("/v1/account/profile", response_model=AccountProfile)
def update_account_profile(
    request: AccountProfileUpdateRequest,
    authorization: str | None = Header(default=None),
) -> AccountProfile:
    try:
        profile = account_store.update_profile(
            token=_bearer_token(authorization), name=request.name,
            height_cm=request.height_cm, avatar_base64=request.avatar_base64,
            update_avatar="avatar_base64" in request.model_fields_set,
        )
        return AccountProfile.model_validate(profile)
    except InvalidCredentialsError as error:
        raise HTTPException(status_code=401, detail=str(error)) from error


@app.post("/v1/auth/logout")
def logout_account(authorization: str | None = Header(default=None)) -> dict[str, bool]:
    account_store.logout(_bearer_token(authorization))
    return {"signed_out": True}


@app.get("/v1/news/feed", response_model=FashionNewsResponse)
async def fashion_news_feed(
    category: Literal[
        "all",
        "y2k",
        "gothic",
        "alternative",
        "formal",
        "casual",
        "wedding",
        "streetwear",
        "vintage",
    ] = "all",
    limit: int = Query(default=16, ge=4, le=30),
) -> FashionNewsResponse:
    return await fashion_news_service.fetch(category=category, limit=limit)


@app.get("/v1/shop/products", response_model=ShopProductsResponse)
async def shop_products(
    limit: int = Query(default=40, ge=1, le=80),
) -> ShopProductsResponse:
    return await shop_catalog_service.fetch(limit=limit)


@app.get("/v1/weather/home", response_model=WeatherHomeResponse)
async def home_weather(
    city: str = Query(default="Manila", min_length=2, max_length=100),
    size_label: str | None = Query(default=None, max_length=12),
    color_season: Literal["Spring", "Summer", "Autumn", "Winter"] | None = None,
) -> WeatherHomeResponse:
    try:
        return await weather_style_service.fetch(
            city=city,
            size_label=size_label,
            color_season=color_season,
        )
    except WeatherServiceError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error
    except httpx.HTTPError as error:
        raise HTTPException(
            status_code=503,
            detail="Live weather is temporarily unavailable. Please try again.",
        ) from error


@app.post("/v1/size/recommend", response_model=SizeResponse)
def recommend_size(request: SizeRequest) -> SizeResponse:
    return engine.recommend_size(request)


@app.post("/v1/body-scan/preview", response_model=BodyScanPreviewResponse)
def preview_body_scan(request: BodyScanPreviewRequest) -> BodyScanPreviewResponse:
    return body_scan_estimator.preview(request)


@app.post("/v1/body-scan/analyze", response_model=BodyScanResponse)
def analyze_body_scan(request: BodyScanRequest) -> BodyScanResponse:
    try:
        return body_scan_estimator.analyze(request)
    except BodyScanError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error


@app.post("/v1/body-scan/profile", response_model=BodyScanResponse)
def body_scan_profile(request: BodyProfileRequest) -> BodyScanResponse:
    """Guided front/side/back scan: widths and depths measured on the phone."""
    try:
        return body_profile_estimator.estimate(request)
    except BodyProfileError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error


@app.post("/v1/profile/analyze", response_model=AppearanceAnalysisResponse)
def analyze_profile_photo(
    request: AppearanceAnalysisRequest,
) -> AppearanceAnalysisResponse:
    try:
        return appearance_analyzer.analyze(request)
    except AppearanceAnalysisError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error


@app.post("/v1/color/analyze", response_model=ColorResponse)
def analyze_color(request: ColorRequest) -> ColorResponse:
    return engine.analyze_color(request)


@app.post("/v1/style/recommend", response_model=StyleResponse)
def recommend_style(request: StyleRequest) -> StyleResponse:
    return engine.recommend_style(request)


@app.post("/v1/outfits/plan", response_model=OutfitPlanResponse)
async def plan_event_outfit(request: OutfitPlanRequest) -> OutfitPlanResponse:
    if request.event_date < datetime.now(UTC).date():
        raise HTTPException(
            status_code=422, detail="Pick a future date for your event."
        )
    try:
        moment = await weather_style_service.fetch_for_datetime(
            request.city, request.event_date, request.event_time
        )
    except WeatherServiceError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error
    except httpx.HTTPError as error:
        raise HTTPException(
            status_code=503,
            detail="Live weather is temporarily unavailable. Please try again.",
        ) from error

    location = moment["location"] if isinstance(moment.get("location"), dict) else {}
    place = str(location.get("name") or request.city.strip())
    occasion = engine.canonicalize_occasion(request.event_text)
    style_used = engine.canonicalize_style(request.style)
    color_season = request.color_season or "Autumn"
    style_result = engine.recommend_style(
        StyleRequest(
            climate=request.climate,
            hemisphere=request.hemisphere,
            month=request.event_date.month,
            occasion=occasion,  # type: ignore[arg-type]
            style=style_used,  # type: ignore[arg-type]
            color_season=color_season,
            size_label=request.size_label,
        )
    )
    temp = moment.get("temperature_c")
    feels = moment.get("feels_like_c")
    rain = moment.get("rain_probability")
    wind = moment.get("wind_kmh")
    uv = moment.get("uv_index_max")
    hour = int(moment.get("hour", 18)) if isinstance(moment.get("hour"), int) else 18
    reasons = engine.event_weather_adjustments(
        temp_c=float(temp) if temp is not None else None,
        feels_c=float(feels) if feels is not None else None,
        rain_probability=int(rain) if rain is not None else None,
        wind_kmh=float(wind) if wind is not None else None,
        uv_index=float(uv) if uv is not None else None,
        hour=hour,
        occasion=occasion,
        event_text=request.event_text,
    )
    is_forecast = bool(moment.get("is_forecast"))
    if not is_forecast:
        source = moment.get("source")
        sample_years = moment.get("sample_years")
        if (
            isinstance(source, str)
            and "climate normals" in source
            and temp is not None
            and isinstance(sample_years, int)
        ):
            reasons = [
                f"Beyond the 16-day forecast, so this uses {sample_years}-year "
                f"averages for this date in {place}."
            ] + reasons
        else:
            reasons = [
                "Beyond the 16-day forecast window, so this is a seasonal "
                "estimate rather than a true forecast."
            ] + reasons

    fit_notes: list[str] = []
    if request.measurements is not None and request.size_label in SIZE_CENTRES:
        fit_notes = engine._fit_notes(
            request.measurements.model_dump(), request.size_label or "M", "regular"
        )

    inspiration_images: list[OutfitInspirationImage] = []
    try:
        query = build_inspiration_query(
            style=style_used,
            pieces=style_result.pieces,
            occasion=occasion,
        )
        for image in await outfit_image_service.fetch_images(query):
            inspiration_images.append(OutfitInspirationImage.model_validate(image))
    except Exception:
        inspiration_images = []

    has_measurements = request.measurements is not None
    has_normals = not is_forecast and temp is not None

    if is_forecast and has_measurements:
        confidence = 0.8
    elif is_forecast:
        confidence = 0.7
    elif has_normals:
        confidence = 0.62
    else:
        confidence = 0.55
    event_time = request.event_time or "18:00"
    return OutfitPlanResponse(
        event_text=request.event_text,
        occasion=occasion,
        style_used=style_used,
        city=request.city.strip(),
        location=place,
        event_datetime=f"{request.event_date.isoformat()}T{event_time}",
        timezone=str(moment.get("timezone", "auto")),
        weather=OutfitPlanWeather(
            temperature_c=float(temp) if temp is not None else None,
            feels_like_c=float(feels) if feels is not None else None,
            condition=str(moment.get("condition", "Mixed conditions")),
            rain_probability=int(rain) if rain is not None else None,
            wind_kmh=float(wind) if wind is not None else None,
            uv_index_max=float(uv) if uv is not None else None,
            is_forecast=is_forecast,
        ),
        title=f"{request.event_text.strip().title()} look: {style_result.title}",
        summary=style_result.summary,
        pieces=style_result.pieces,
        fabrics=style_result.fabrics,
        palette=style_result.palette,
        styling_notes=style_result.styling_notes,
        fit_notes=fit_notes,
        reasons=reasons,
        confidence=confidence,
        inspiration_images=inspiration_images,
        model_version=f"event-outfit-0.1.0+{style_result.model_version}",
        disclaimer=(
            "Forecast-based styling suggestion, not a guarantee. Weather can "
            "shift; confirm sizes against each seller chart. "
            + (
                "This uses climate averages for the date, not a live forecast."
                if has_normals
                else (
                    "This uses a seasonal estimate, not a live forecast."
                    if not is_forecast
                    else "Check the forecast again near the event."
                )
            )
        ),
    )
