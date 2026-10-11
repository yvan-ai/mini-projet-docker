from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, StringConstraints


class TaskIn(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]


class TaskOut(BaseModel):
    id: int
    title: str
    done: bool
    created_at: datetime
    done_at: datetime | None
