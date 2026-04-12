from dataclasses import dataclass


@dataclass
class GPSReading:
    latitude: float
    longitude: float
    fix_status: str


class GPSManager:
    def __init__(self) -> None:
        self.last_latitude = 1.3521
        self.last_longitude = 103.8198

    def update_from_phone(
        self, latitude: float | None, longitude: float | None
    ) -> None:
        if latitude is None or longitude is None:
            return
        self.last_latitude = latitude
        self.last_longitude = longitude

    def read(self) -> GPSReading:
        return GPSReading(
            latitude=self.last_latitude,
            longitude=self.last_longitude,
            fix_status="FIX_3D",
        )
