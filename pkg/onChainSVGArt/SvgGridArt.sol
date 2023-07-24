// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract PixelArtContract {
    // The size of the grid
    uint256 public constant GRID_SIZE = 10;

    // The default color
    string public constant DEFAULT_COLOR = "white";

    // Struct to represent a grid cell
    struct Cell {
        bool isSet;
        string color;
    }

    // Mapping from user address to their grid
    mapping(address => Cell[GRID_SIZE][GRID_SIZE]) public grids;

    // Function to set the color of a cell in a user's grid
    function setCellColor(uint256 x, uint256 y, string memory color) public {
        require(x < GRID_SIZE && y < GRID_SIZE, "Cell coordinates are out of bounds");

        grids[msg.sender][x][y] = Cell(true, color);
    }

    // Function to get a user's grid as an SVG string
    function getSvg(address user) public view returns (string memory) {
        string memory svgStart = "<svg xmlns='http://www.w3.org/2000/svg' width='500' height='500'>";
        string memory svgEnd = "</svg>";
        string memory svgCells = "";

        for (uint256 x = 0; x < GRID_SIZE; x++) {
            for (uint256 y = 0; y < GRID_SIZE; y++) {
                Cell memory cell = grids[user][x][y];

                string memory color = cell.isSet ? cell.color : DEFAULT_COLOR;

                svgCells = string(abi.encodePacked(svgCells, "<rect x='", uintToStr(x * 50), "' y='", uintToStr(y * 50), "' width='50' height='50' style='fill:", color, ";'/>"));
            }
        }

        return string(abi.encodePacked(svgStart, svgCells, svgEnd));
    }

    // Function to convert a uint to a string (for SVG generation)
    function uintToStr(uint256 _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        return string(bstr);
    }
}