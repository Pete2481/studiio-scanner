import Foundation
import AppKit
import SwiftUI

/// Exports floor plans as A3 landscape PDF files with Australian disclaimer and branding.
enum PDFExporter {

    // MARK: - Page Dimensions

    /// A3 landscape at 72 DPI: 1190.55 x 841.89 points (420mm x 297mm)
    static let a3Width: CGFloat = 1190.55
    static let a3Height: CGFloat = 841.89
    static let pageSize = CGSize(width: a3Width, height: a3Height)

    // MARK: - Margins

    static let marginTop: CGFloat = 40
    static let marginBottom: CGFloat = 80 // space for disclaimer + address
    static let marginLeft: CGFloat = 40
    static let marginRight: CGFloat = 40

    // MARK: - Australian Disclaimer

    static let disclaimer = """
    All measurements and calculations are approximate only. \
    Information herein is believed to be correct but is not guaranteed. \
    Produced in accordance with RICS Property Measurement Standards. \
    Buyers should make their own enquiries. \
    Created by Studiio Scanner.
    """

    // MARK: - Export Single Floor

    /// Export a single floor plan to PDF data.
    @MainActor
    static func exportFloor(
        layout: FloorPlanLayout,
        address: String?,
        projectDate: Date
    ) -> Data {
        let renderer = ImageRenderer(
            content: PDFPageView(
                layout: layout,
                address: address,
                pageSize: pageSize
            )
        )
        renderer.proposedSize = .init(pageSize)

        let pdfData = NSMutableData()
        renderer.render { size, render in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: pdfData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

            context.beginPDFPage(nil)
            render(context)
            context.endPDFPage()
            context.closePDF()
        }

        return pdfData as Data
    }

    // MARK: - Export Multi-Floor (all on one page)

    /// Export all floors side by side on a single A3 page (Roomio style).
    @MainActor
    static func exportProject(
        project: PropertyProject
    ) -> Data {
        let floors = project.floors.map { FloorPlanExtractor.extractLayout(from: $0) }
        let totalArea = project.floors.flatMap(\.rooms).reduce(0.0) { $0 + $1.area }

        let renderer = ImageRenderer(
            content: MultiFloorPDFPageView(
                layouts: floors,
                address: project.address,
                totalArea: totalArea,
                pageSize: pageSize
            )
        )
        renderer.proposedSize = .init(pageSize)

        let pdfData = NSMutableData()
        renderer.render { size, render in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: pdfData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

            context.beginPDFPage(nil)
            render(context)
            context.endPDFPage()
            context.closePDF()
        }

        return pdfData as Data
    }

    // MARK: - Save to File

    static func savePDF(data: Data, to url: URL) throws {
        try data.write(to: url)
    }
}

// MARK: - Single Floor PDF Page

struct PDFPageView: View {
    let layout: FloorPlanLayout
    let address: String?
    let pageSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white

            VStack(spacing: 0) {
                // Blueprint area
                BlueprintRenderer(
                    layout: layout,
                    canvasSize: CGSize(
                        width: pageSize.width - PDFExporter.marginLeft - PDFExporter.marginRight,
                        height: pageSize.height - PDFExporter.marginTop - PDFExporter.marginBottom - 20
                    )
                )
                .padding(.top, PDFExporter.marginTop)
                .padding(.horizontal, PDFExporter.marginLeft)

                Spacer()

                // Footer
                footerView
            }

            // North arrow top-right
            northArrow
                .position(x: pageSize.width - 60, y: 50)
        }
        .frame(width: pageSize.width, height: pageSize.height)
    }

    private var footerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .background(Color.black)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let address = address {
                        Text(address.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                    }

                    Text(String(format: "TOTAL APPROX. FLOOR AREA %.0f SQ.M", layout.totalArea))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.black)
                }

                Spacer()

                Text("Studiio")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.0))
            }

            Text(PDFExporter.disclaimer)
                .font(.system(size: 6))
                .foregroundColor(Color(white: 0.4))
                .lineLimit(3)
        }
        .padding(.horizontal, PDFExporter.marginLeft)
        .padding(.bottom, 12)
    }

    private var northArrow: some View {
        VStack(spacing: 2) {
            Text("N")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.black)

            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.black)
        }
    }
}

// MARK: - Multi-Floor PDF Page

struct MultiFloorPDFPageView: View {
    let layouts: [FloorPlanLayout]
    let address: String?
    let totalArea: Double
    let pageSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white

            VStack(spacing: 0) {
                // Floors side by side
                HStack(alignment: .top, spacing: PDFExporter.marginLeft) {
                    let floorWidth = (pageSize.width - PDFExporter.marginLeft * CGFloat(layouts.count + 1)) / CGFloat(max(layouts.count, 1))
                    let floorHeight = pageSize.height - PDFExporter.marginTop - PDFExporter.marginBottom - 40

                    ForEach(layouts.indices, id: \.self) { index in
                        VStack(spacing: 4) {
                            Text(layouts[index].floorName.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.black)

                            BlueprintRenderer(
                                layout: layouts[index],
                                canvasSize: CGSize(width: floorWidth, height: floorHeight),
                                showDimensions: true,
                                showObjectLabels: true
                            )
                        }
                    }
                }
                .padding(.top, PDFExporter.marginTop)
                .padding(.horizontal, PDFExporter.marginLeft)

                Spacer()

                // Footer
                multiFooterView
            }

            // North arrow top-right
            VStack(spacing: 2) {
                Text("N")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black)
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
            }
            .position(x: pageSize.width - 60, y: 50)
        }
        .frame(width: pageSize.width, height: pageSize.height)
    }

    private var multiFooterView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .background(Color.black)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let address = address {
                        Text(address.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                    }

                    Text(String(format: "TOTAL APPROX. FLOOR AREA %.0f SQ.M", totalArea))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.black)
                }

                Spacer()

                Text("Studiio")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.0))
            }

            Text(PDFExporter.disclaimer)
                .font(.system(size: 6))
                .foregroundColor(Color(white: 0.4))
                .lineLimit(3)
        }
        .padding(.horizontal, PDFExporter.marginLeft)
        .padding(.bottom, 12)
    }
}
