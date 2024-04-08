abstract type AbstractDocument end
abstract type AbstractCachedDocument <: AbstractDocument end

function rasterize end
function draw_to_cairo_surface end

"""
    SVGDocument(svg::AbstractString)

A document type which stores an SVG string.

Is converted to [`CachedSVG`](@ref) for use in plotting.
"""
struct SVGDocument <: AbstractDocument
    svg::String
end

"""
    PDFDocument(pdf::AbstractString)

A document type which holds a raw PDF as a string.

Is converted to [`CachedPDF`](@ref) for use in plotting.
"""
struct PDFDocument <: AbstractDocument
    pdf::String
end

"""
    EPSDocument(eps::AbstractString)

A document type which holds an EPS string.

Is converted to [`CachedPDF`](@ref) for use in plotting.
"""
struct EPSDocument <: AbstractDocument
    eps::String
end

struct TeXDocument <: AbstractDocument
    contents::String
end

"""
    TeXDocument(contents::AbstractString, add_defaults::Bool; requires, preamble, class, classoptions)

This constructor function creates a `struct` of type `TeXDocument` which can be passed to `teximg`.
All arguments are to be passed as strings.

If `add_defaults` is `false`, then we will *not* automatically add document structure.
Note that in this case, keyword arguments will be disregarded and `contents` must be
a complete LaTeX document.

Available keyword arguments are:
- `requires`: code which comes before `documentclass` in the preamble.  Default: `raw"\\RequirePackage{luatex85}"`.
- `class`: the document class.  Default (and what you should use): `"standalone"`.
- `classoptions`: the options you should pass to the class, i.e., `\\documentclass[\$classoptions]{\$class}`.  Default: `"preview, tightpage, 12pt"`.
- `preamble`: arbitrary code for the preamble (between `\\documentclass` and `\\begin{document}`).  Default: `raw"\\usepackage{amsmath, xcolor} \\pagestyle{empty}"`.

See also [`CachedTeX`](@ref), [`compile_latex`](@ref), etc.
"""
function TeXDocument(
            contents::AbstractString,
            add_defaults::Bool;
            requires::AbstractString = raw"\RequirePackage{luatex85}",
            class::AbstractString = "standalone",
            classoptions::AbstractString = "preview, tightpage, 12pt",
            preamble::AbstractString = raw"""
                        \usepackage{amsmath, xcolor}
                        \pagestyle{empty}
                        """,
        )
        if add_defaults
            return TeXDocument(
                """
                $(requires)

                \\documentclass[$(classoptions)]{$(class)}

                $(preamble)

                \\begin{document}

                $(contents)

                \\end{document}
                """
            )
        else
            return TeXDocument(contents)
        end
end

"""
    texdoc(contents::AbstractString; kwargs...)

A shorthand for `TeXDocument(contents, add_defaults=true; kwargs...)`.

Available keyword arguments are:

- `requires`: code which comes before `documentclass` in the preamble.  Default: `raw"\\RequirePackage{luatex85}"`.
- `class`: the document class.  Default (and what you should use): `"standalone"`.
- `classoptions`: the options you should pass to the class, i.e., `\\documentclass[\$classoptions]{\$class}`.  Default: `"preview, tightpage, 12pt"`.
- `preamble`: arbitrary code for the preamble (between `\\documentclass` and `\\begin{document}`).  Default: `raw"\\usepackage{amsmath, xcolor} \\pagestyle{empty}"`.

"""
texdoc(contents; kwargs...) = TeXDocument(contents, true; kwargs...)

function Base.convert(::Type{String}, doc::TeXDocument)
    return Base.convert(String, doc.contents)
end

mutable struct CachedTeX <: AbstractCachedDocument
    "The original `TeXDocument` which is compiled."
    doc::Union{TeXDocument, Nothing}
    "The resulting compiled PDF"
    pdf::Vector{UInt8}
    "A pointer to the Poppler handle of the PDF.  May be randomly GC'ed by Poppler."
    ptr::Ptr{Cvoid} # Poppler handle
    "A surface to which Poppler has drawn the PDF.  Permanent and cached."
    surf::CairoSurface
    "The dimensions of the PDF page, for ease of access."
    dims::Tuple{Float64, Float64}
end

"""
    CachedPDF(pdf::PDFDocument)



## Usage
```julia
CachedPDF(read("path/to/pdf.pdf"), [page = 0])
CachedPDF(read("path/to/pdf.pdf", String), [page = 0])
CachedPDF(PDFDocument(...), [page = 0])
```
"""
struct CachedPDF <: AbstractCachedDocument
    "A reference to the `PDFDocument` which is cached here."
    pdf::PDFDocument
    "A pointer to the Poppler handle of the PDF.  May be randomly GC'ed by Poppler."
    poppler::Ref{Ptr{Cvoid}}
    "The dimensions of the PDF page in points, for ease of access."
    dims::Tuple{Float64, Float64}
    "A Cairo surface to which Poppler has drawn the PDF.  Permanent and cached."
    surf::CairoSurface
    "A cache for a (rendered_image, scale_factor) pair.  This is used to avoid re-rendering the PDF."
    image_cache::Ref{Tuple{Matrix{ARGB32}, Float64}}
end

function CachedPDF(pdf::PDFDocument, poppler_handle::Ptr{Cvoid}, dims::Tuple{Float64, Float64}, surf::CairoSurface)
    return CachedPDF(pdf, Ref(poppler_handle), dims, surf, Ref{Tuple{Matrix{ARGB32}, Float64}}((Matrix{ARGB32}(undef, 0, 0), 0)))
end

function CachedPDF(pdf::PDFDocument, page::Int = 0)
    pdf = Vector{UInt8}(pdf.pdf)
    ptr = load_pdf(pdf)
    surf = page2recordsurf(ptr, page)
    dims = pdf_get_page_size(ptr, page)

    return CachedPDF(pdf, Ref(ptr), dims, surf)
end

struct CachedSVG <: AbstractCachedDocument
    svg::SVGDocument
    handle::Ref{Rsvg.RsvgHandle}
    dims::Tuple{Float64, Float64}
    surf::CairoSurface
end

"""
    CachedTeX(doc::TeXDocument; kwargs...)

Compile a `TeXDocument`, compile it and return the cached TeX object.

A `CachedTeX` struct stores the document and its compiled form, as well as some
pointers to in-program versions of it.  It also stores the page dimensions.

In `kwargs`, one can pass anything which goes to the internal function `compile_latex`.
These are primarily:
- `engine = \`lualatex\`/\`xelatex\`/...`: the LaTeX engine to use when rendering
- `options=\`-file-line-error\``: the options to pass to `latexmk`.

The constructor stores the following fields:
$(FIELDS)

!!! note
    This is a `mutable struct` because the pointer to the Poppler handle can change.
    TODO: make this an immutable struct with a Ref to the handle??  OR maybe even the surface itself...

!!! note
    It is also possible to manually construct a `CachedTeX` with `nothing` in the `doc` field, 
    if you just want to insert a pre-rendered PDF into your figure.
"""
function CachedTeX(doc::TeXDocument; kwargs...)

    pdf = Vector{UInt8}(latex2pdf(convert(String, doc); kwargs...))
    ptr = load_pdf(pdf)
    surf = firstpage2recordsurf(ptr)
    dims = (pdf_get_page_size(ptr, 0))

    ct = CachedTeX(
        doc,
        pdf,
        ptr,
        surf,
        dims# .+ (1, 1),
    )

    return ct
end

function CachedTeX(str::String; kwargs...)
    return CachedTeX(implant_text(str); kwargs...)
end

function CachedTeX(x::LaTeXString; kwargs...)
    x = convert(String, x)
    return if first(x) == "\$" && last(x) == "\$"
        CachedTeX(implant_math(x[2:end-1]); kwargs...)
    else
        CachedTeX(implant_text(x); kwargs...)
    end
end

function CachedTeX(pdf::Vector{UInt8}; kwargs...)
    ptr = load_pdf(pdf)
    surf = firstpage2recordsurf(ptr)
    dims = pdf_get_page_size(ptr, 0)

    ct = CachedTeX(
        nothing,
        pdf,
        ptr,
        surf,
        dims# .+ (1, 1),
    )
    return ct
end

# do not rerun the pipeline on CachedTeX
CachedTeX(ct::CachedTeX) = ct

function update_pointer!(ct::CachedTeX)
    ct.ptr = load_pdf(ct.pdf)
    return ct.ptr
end

function Base.show(io::IO, ct::CachedTeX)
    if isnothing(doc)
        println(io, "CachedTeX(no document, $(ct.ptr), $(ct.dims))")
    elseif length(ct.doc.contents) > 1000
        println(io, "CachedTeX(TexDocument(...), $(ct.ptr), $(ct.dims))")
    else
        println(io, "CachedTeX($(ct.doc), $(ct.ptr), $(ct.dims))")
    end
end

function implant_math(str)
    return TeXDocument(
        """\\(\\displaystyle $str\\)""", true;
        requires = "\\RequirePackage{luatex85}",
        preamble = """
        \\usepackage{amsmath, amsfonts, xcolor}
        \\pagestyle{empty}
        \\nopagecolor
        """,
        class = "standalone",
        classoptions = "preview, tightpage, 12pt",
    )
end

function implant_text(str)
    return TeXDocument(
        String(str), true;
        requires = "\\RequirePackage{luatex85}",
        preamble = """
        \\usepackage{amsmath, amsfonts, xcolor}
        \\pagestyle{empty}
        \\nopagecolor
        """,
        class = "standalone",
        classoptions = "preview, tightpage, 12pt"
    )
end


# Define bounding box methods for CachedTex

"""
Calculate an approximation of a tight rectangle around a 2D rectangle rotated by `angle` radians.
This is not perfect but works well enough. Check an A vs X to see the difference.
"""
function rotatedrect(rect::Rect{2, T}, angle)::Rect{2, T} where T
    ox, oy = rect.origin
    wx, wy = rect.widths
    points = Makie.Mat{2, 4, T}(
        ox, oy,
        ox, oy+wy,
        ox+wx, oy,
        ox+wx, oy+wy
    )
    mrot = Makie.Mat{2, 2, T}(
        cos(angle), -sin(angle),
        sin(angle), cos(angle)
    )
    rotated = mrot * points

    rmins = minimum(rotated; dims=2)
    rmaxs = maximum(rotated; dims=2)

    return Rect2(rmins..., (rmaxs .- rmins)...)
end

function Makie.boundingbox(cachedtex::CachedTeX, position, rotation, scale,
    align)
    origin = offset_from_align(align, cachedtex.dims)
    box = Rect2f(Point2f(origin), Vec2f(cachedtex.dims) * scale)
    rect = rotatedrect(box, rotation)
    new_origin = Point3f(rect.origin..., 0)
    new_widths = Vec3f(rect.widths..., 0)
    return Rect3f(new_origin + position, new_widths)
end

# this method copied from Makie.jl
function Makie.boundingbox(cachedtexs::AbstractVector{CachedTeX}, positions, rotations, scale,
    align)

    isempty(cachedtexs) && (return Rect3f((0, 0, 0), (0, 0, 0)))

    bb = Rect3f()
    broadcast_foreach(cachedtexs, positions, rotations, scale,
    align) do cachedtex, pos, rot, scl, aln
        if !Makie.isfinite_rect(bb)
            bb = Makie.boundingbox(cachedtex, pos, rot, scl, aln)
        else
            bb = Makie.union(bb, Makie.boundingbox(cachedtex, pos, rot, scl, aln))
        end
    end
    !Makie.isfinite_rect(bb) && error("Invalid `TeX` boundingbox")
    return bb
end
