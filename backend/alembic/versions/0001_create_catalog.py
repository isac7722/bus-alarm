"""Create station catalog tables."""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Create normalized stations, routes, and route stops."""
    op.create_table(
        "stations",
        sa.Column("station_id", sa.String(5), primary_key=True),
        sa.Column("node_id", sa.String(9), nullable=False, index=True),
        sa.Column("name", sa.String(128), nullable=False, index=True),
        sa.Column("longitude", sa.Float(), nullable=False),
        sa.Column("latitude", sa.Float(), nullable=False),
    )
    op.create_table(
        "routes",
        sa.Column("route_id", sa.String(9), primary_key=True),
        sa.Column("name", sa.String(128), nullable=False, index=True),
    )
    op.create_table(
        "route_stops",
        sa.Column("route_id", sa.String(9), sa.ForeignKey("routes.route_id", ondelete="CASCADE"), primary_key=True),
        sa.Column("sequence", sa.Integer(), primary_key=True),
        sa.Column("station_id", sa.String(5), sa.ForeignKey("stations.station_id", ondelete="CASCADE"), nullable=False),
        sa.UniqueConstraint("route_id", "station_id", "sequence", name="uq_route_stop"),
    )
    op.create_index("ix_route_stops_station_id", "route_stops", ["station_id"])


def downgrade() -> None:
    """Drop the catalog tables."""
    op.drop_table("route_stops")
    op.drop_table("routes")
    op.drop_table("stations")

