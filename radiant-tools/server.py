"""Serveur MCP « viz » — outils de visualisation réutilisables pour l'assistant Radiant.

POC : premier outil = diagramme de Venn d'un trio (intersections des SNV).
L'agent calcule les comptes des 7 régions via UNE requête StarRocks (recette
dans ses instructions), puis appelle venn_trio qui rend l'image. Aucune donnée
patient ne transite ici : uniquement des comptes agrégés et des étiquettes de rôle.
"""

import io

from matplotlib import pyplot as plt
from matplotlib_venn import venn2, venn3
from matplotlib_venn.layout.venn2 import DefaultLayoutAlgorithm as Venn2Layout
from matplotlib_venn.layout.venn3 import DefaultLayoutAlgorithm as Venn3Layout
from mcp.server.fastmcp import FastMCP, Image

# Port explicite : biomcp occupe déjà 8000 dans le namespace réseau partagé.
mcp = FastMCP("viz", host="127.0.0.1", port=8001)


@mcp.tool()
def venn_trio(
    proband_only: int,
    father_only: int,
    mother_only: int,
    proband_father: int,
    proband_mother: int,
    father_mother: int,
    all_three: int,
    proband_label: str = "Proband",
    father_label: str = "Father",
    mother_label: str = "Mother",
    title: str = "Trio SNV overlap",
) -> Image:
    """Render a (non-scaled) 3-set Venn diagram of SNV counts for a trio.

    Each argument is the count of variants in EXACTLY that region (e.g.
    `proband_father` = present in proband AND father but NOT mother).
    Returns a PNG image displayed inline in the conversation.
    """
    fig, ax = plt.subplots(figsize=(7, 6))
    # Cercles de taille fixe (non à l'échelle) pour rester lisibles quels que soient les comptes.
    # Ordre matplotlib-venn : (A, B, AB, C, AC, BC, ABC) avec A=proband, B=father, C=mother
    v = venn3(
        subsets=(proband_only, father_only, proband_father, mother_only,
                 proband_mother, father_mother, all_three),
        set_labels=(proband_label, father_label, mother_label),
        ax=ax,
        # Cercles de taille fixe (non à l'échelle) : lisible quels que soient les comptes
        layout_algorithm=Venn3Layout(fixed_subset_sizes=(1, 1, 1, 1, 1, 1, 1)),
        # Palette pastel (référence Vincent) : proband bleu, père vert, mère pêche
        set_colors=("#89B8E0", "#96D096", "#F4B183"),
        alpha=0.5,
    )
    # Cercles non à l'échelle : venn3 pondère par défaut ; on force des tailles lisibles
    for text in v.set_labels:
        if text:
            text.set_fontsize(13)
    for text in v.subset_labels:
        if text:
            text.set_fontsize(12)
            text.set_text(f"{int(float(text.get_text())):,}".replace(",", " "))
    ax.set_title(title, fontsize=14)
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=110, bbox_inches="tight")
    plt.close(fig)
    return Image(data=buf.getvalue(), format="png")


@mcp.tool()
def venn_duo(
    proband_only: int,
    other_only: int,
    both: int,
    proband_label: str = "Proband",
    other_label: str = "Parent",
    title: str = "Duo SNV overlap",
) -> Image:
    """Render a (non-scaled) 2-set Venn diagram of SNV counts for a duo
    (proband + one family member, e.g. when a parent is missing).

    `proband_only` / `other_only` = counts exclusive to each member;
    `both` = shared variants. Returns a PNG image displayed inline.
    """
    fig, ax = plt.subplots(figsize=(6.5, 5.5))
    v = venn2(
        subsets=(proband_only, other_only, both),
        set_labels=(proband_label, other_label),
        ax=ax,
        layout_algorithm=Venn2Layout(fixed_subset_sizes=(1, 1, 1)),
        set_colors=("#89B8E0", "#F4B183"),
        alpha=0.5,
    )
    for text in v.set_labels:
        if text:
            text.set_fontsize(13)
    for text in v.subset_labels:
        if text:
            text.set_fontsize(12)
            text.set_text(f"{int(float(text.get_text())):,}".replace(",", " "))
    ax.set_title(title, fontsize=14)
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=110, bbox_inches="tight")
    plt.close(fig)
    return Image(data=buf.getvalue(), format="png")


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
