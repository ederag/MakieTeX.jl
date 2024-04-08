module MakieTeXCairoMakieExt

using CairoMakie, MakieTeX
using MakieTeX.Makie
using MakieTeX.Makie.MakieCore
using MakieTeX.Poppler_jll
using MakieTeX.Cairo
using MakieTeX.Colors

# CairoMakie direct drawing method
function draw_tex(scene, screen::CairoMakie.Screen, cachedtex::MakieTeX.CachedTeX, position::VecTypes, scale::VecTypes, rotation::Real, align::Tuple{Symbol, Symbol})
    # establish some initial values
    w, h = cachedtex.dims
    ctx = screen.context
    # First we center the position with respect to the center of the image,
    # regardless of its alignment.  This ensures that rotation takes place
    # in the correct "axis" (2d).
    position = position .+ (-scale[1]/2, scale[2]/2)


    # Then, we find the appropriate "marker offset" w.r.t. alignment.
    # This is separate because of Cairo's reversed y-axis.
    halign, valign = align
    offset_pos = Point2f(0)
    # First, we handle the horizontal alignment
    offset_pos = if halign == :left
        offset_pos .- (-scale[1] / 2, 0)
    elseif halign == :center
        offset_pos .- (0, 0)
    elseif halign == :right
        offset_pos .- (scale[1] / 2, 0)
    end
    # and then the vertical alignment.
    offset_pos = if valign == :top
        offset_pos .+ (0, scale[2]/2)
    elseif valign == :center
        offset_pos .+ (0, 0)
    elseif valign == :bottom
        offset_pos .- (0, scale[2]/2)
    end

    # Calculate, with respect to the rotation, where the rotated center of the image
    # should be.
    # (Rotated center - Normal center)
    cx = 0.5scale[1] * cos(rotation) - 0.5scale[2] * sin(rotation) - 0.5scale[1]
    cy = 0.5scale[1] * sin(rotation) + 0.5scale[2] * cos(rotation) - 0.5scale[2]

    # Begin the drawing and translation process
    Cairo.save(ctx)
    # translate to normal position
    Cairo.translate(
        ctx,
        position[1],
        position[2] - scale[2]
    )
    # rotate context by required rotation
    Cairo.rotate(ctx, -rotation)
    # cairo rotates around position as an axis,
    #compensate for that with previously calculated values
    Cairo.translate(ctx, cx, cy)
    # apply "marker offset" to implement/simulate alignment
    Cairo.translate(ctx, offset_pos[1], offset_pos[2])
    # scale the marker appropriately
    Cairo.scale(
        ctx,
        scale[1] / w,
        scale[2] / h
    )
    # the rendering pipeline
    # first is the "safe" Poppler pipeline, with better results in PDF
    # and PNG, especially when rotated.
    if !(MakieTeX.RENDER_EXTRASAFE[])
        # retrieve a new Poppler document pointer
        document = MakieTeX.update_pointer!(cachedtex)
        # retrieve the first page
        page = ccall(
            (:poppler_document_get_page, Poppler_jll.libpoppler_glib),
            Ptr{Cvoid},
            (Ptr{Cvoid}, Cint),
            document, 0 # page 0 is first page
        )
        # Render the page to the surface
        ccall(
            (:poppler_page_render, Poppler_jll.libpoppler_glib),
            Cvoid,
            (Ptr{Cvoid}, Ptr{Cvoid}),
            page, ctx.ptr
        )
    else # "extra-safe" Cairo pipeline, also somewhat faster.
        # render the cached CairoSurface to the screen.
        # bad with PNG output though.
        Cairo.set_source(ctx, cachedtex.surf, 0, 0)
        Cairo.paint(ctx)
    end
    # restore context and end
    Cairo.restore(ctx)
end

# Override `is_cairomakie_atomic_plot` to allow `TeXImg` to remain a unit,
# instead of auto-decomposing into its component scatter plot.
CairoMakie.is_cairomakie_atomic_plot(plot::TeXImg) = true

function CairoMakie.draw_plot(scene::Makie.Scene, screen::CairoMakie.Screen, img::T) where T <: MakieTeX.TeXImg

    broadcast_foreach(img[1][], img.position[], img.scale[], CairoMakie.remove_billboard(img.rotation[]), img.align[]) do cachedtex, position, scale, rotation, align

        w, h = cachedtex.dims

        pos = CairoMakie.project_position(
            scene, img.space[],
            Makie.apply_transform(scene.transformation.transform_func[], position),
            img.model[]
        )

        _w = scale * w; _h = scale * h
        scale_factor = CairoMakie.project_scale(scene, img.space[], Vec2{Float32}(_w, _h), img.model[])

        draw_tex(scene, screen, cachedtex, pos, scale_factor, rotation, align)

    end

end

function CairoMakie.draw_marker(ctx, marker::MakieTeX.CachedSVG, pos, scale,
    strokecolor #= unused =#, strokewidth #= unused =#,
    marker_offset, rotation) 

    # convert marker to Cairo compatible image data
    marker_surf = marker.surf

    w, h = marker.dims

    Cairo.translate(ctx,
                    scale[1]/2 + pos[1] + marker_offset[1],
                    scale[2]/2 + pos[2] + marker_offset[2])
    Cairo.rotate(ctx, to_2d_rotation(rotation))
    Cairo.scale(ctx, scale[1] / w, scale[2] / h)
    Cairo.set_source_surface(ctx, marker_surf, -w/2, -h/2)
    Cairo.paint(ctx)
end



end