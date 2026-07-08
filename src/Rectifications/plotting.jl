function get_warp(ratio, real2image)
    D = LinearMap(SDiagonal{2}(ratio*I))
    real2image ∘ D
end

function warp_extrinsic(file, extrinsic, width, height, warp_trans)
    m = min(width, height)
    _img = _frame_at(file, extrinsic, missing, width, height)
    img = colorview(Gray, normedview(_img))
    imgw = warp(img, warp_trans, (-m÷2:m÷2, -m÷2:m÷2))
end


