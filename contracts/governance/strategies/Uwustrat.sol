// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

import "@rari-capital/solmate/src/tokens/ERC20.sol";
import "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/*
 * The Stability Pool holds LUSD tokens deposited by Stability Pool depositors.
 *
 * When a trove is liquidated, then depending on system conditions, some of its LUSD debt gets offset with
 * LUSD in the Stability Pool:  that is, the offset debt evaporates, and an equal amount of LUSD tokens in the Stability Pool is burned.
 *
 * Thus, a liquidation causes each depositor to receive a LUSD loss, in proportion to their deposit as a share of total deposits.
 * They also receive an ETH gain, as the ETH collateral of the liquidated trove is distributed among Stability depositors,
 * in the same proportion.
 *
 * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total LUSD in the Stability Pool, depletes 40% of each deposit.
 *
 * A deposit that has experienced a series of liquidations is termed a "compounded deposit": each liquidation depletes the deposit,
 * multiplying it by some factor in range ]0,1[
 *
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / ETH gain derivations:
 * https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 *
 * --- TEDDY ISSUANCE TO STABILITY POOL DEPOSITORS ---
 *
 * An TEDDY issuance event occurs at every deposit operation, and every liquidation.
 *
 * Each deposit is tagged with the address of the front end through which it was made.
 *
 * All deposits earn a share of the issued TEDDY in proportion to the deposit as a share of total deposits. The TEDDY earned
 * by a given deposit, is split between the depositor and the front end through which the deposit was made, based on the front end's kickbackRate.
 *
 * Please see the system Readme for an overview:
 * https://github.com/liquity/dev/blob/main/README.md#TEDDY-issuance-to-stability-providers
 */
interface IStabilityPool {

    /*
     * Initial checks:
     * - Frontend is registered or zero address
     * - Sender is not a registered frontend
     * - _amount is not zero
     * ---
     * - Triggers a TEDDY issuance, based on time passed since the last issuance. The TEDDY issuance is shared between *all* depositors and front ends
     * - Tags the deposit with the provided front end tag param, if it's a new deposit
     * - Sends depositor's accumulated gains (TEDDY, ETH) to depositor
     * - Sends the tagged front end's accumulated TEDDY gains to the tagged front end
     * - Increases deposit and tagged front end's stake, and takes new snapshots for each.
     */
    function provideToSP(uint _amount, address _frontEndTag) external;

    /*
     * Initial checks:
     * - _amount is zero or there are no under collateralized troves left in the system
     * - User has a non zero deposit
     * ---
     * - Triggers a TEDDY issuance, based on time passed since the last issuance. The TEDDY issuance is shared between *all* depositors and front ends
     * - Removes the deposit's front end tag if it is a full withdrawal
     * - Sends all depositor's accumulated gains (TEDDY, ETH) to depositor
     * - Sends the tagged front end's accumulated TEDDY gains to the tagged front end
     * - Decreases deposit and tagged front end's stake, and takes new snapshots for each.
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdrawFromSP(uint _amount) external;
}

contract TEDDYStratV1 is ERC20("Compounded TSD", "cTSD", 18) {

    ///////////////////////////////////////////////////////
    /////////////////////  CONSTANTS  /////////////////////
    ///////////////////////////////////////////////////////
    /// @notice IUniswapV2Router02 - TraderJoeXYZ Router
    IUniswapV2Router02 public constant JOE_ROUTER = IUniswapV2Router02(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
    /// @notice IUniswapV2Router02 - Pangolin AMM Router
    IUniswapV2Router02 public constant PANGO_ROUTER = IUniswapV2Router02(0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106);
    /// @notice ERC20 - Wrapped AVAX
    ERC20 public constant WAVAX = ERC20();
    /// @notice ERC20 - Teddy USD
    ERC20 public constant TSD = ERC20(0x4fbf0429599460D327BD5F55625E30E4fC066095);
    /// @notice ERC20 - Teddy DAO Token
    ERC20 public constant TEDDY = ERC20(0x094bd7B2D99711A1486FB94d4395801C6d0fdDcC);
    /// @notice IStabilityPool - Stable pool that's being compounded
    IStabilityPool public constant pool = IStabilityPool();
    /// @notice Number - Divisor used when calculating fees
    uint256 public constant DIVISOR = 1e18; // 100 %
    /// @notice Number - Numerator used when calcuting reinvest fee
    uint256 public constant REINVEST_FEE = 1e18 / 100; // 1 %
    /// @notice Number - Numerator used when calculating performance fee
    uint256 public constant PERFORMANCE_FEE = 1e18 / 100 * 2; // 2 %
    ///////////////////////////////////////////////////////
    //////////////////////  STORAGE  //////////////////////
    ///////////////////////////////////////////////////////
    /// @notice EOA - contract manager (can only adjust reinvest threshold, 
    /// and whether the pool reinvests on deposits)
    address public admin = msg.sender;
    /// @notice Teddy balance threshold which must be exceeded to call reinveset function
    uint256 public threshold;
    /// @notice Reinvest fee + performance fee
    uint256 public totalFeeBalances;
    /// @notice Number - Tracks pool profit
    uint256 public cummulativeProfit;
    /// @notice boolean which determines whether reinvest function will be called on mint/burn interactions
    bool public reinvestOnInteraction;
    /// @notice Number - Stores the fee balance of each account
    mapping(address => uint256) public feeBalanceOf;

    ///////////////////////////////////////////////////////
    ///////////////////  CONSTRUCTION  ////////////////////
    ///////////////////////////////////////////////////////

    /// @notice TSD is maxApproved at initialization
    constructor() {
        TSD.approve(address(pool), type(uint256).max);
    }

    ///////////////////////////////////////////////////////
    ////////////////////  ADMIN ONLY  /////////////////////
    ///////////////////////////////////////////////////////

    modifier onlyAdmin() {
        require(msg.sender == admin, "dev: wut?");
        _;
    }

    function set_Reinvest(bool autoReinvest) external onlyAdmin {
        reinvestOnInteraction = autoReinvest;
    }

    function set_Threshold(uint256 newThreshold) external onlyAdmin {
        threshold = newThreshold;
    }

    function set_Admin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
    }
    
    ///////////////////////////////////////////////////////
    //////////////////////  PUBLIC LOGIC //////////////////
    ///////////////////////////////////////////////////////

    function mint(address to, uint256 amountIn) external returns (uint256 amountOut) {

        if (reinvestOnInteraction) reinvest();

        SafeTransferLib.safeTransferFrom(TSD, msg.sender, address(this), amountIn);

        if (TSD.allowance(address(this), address(pool)) <  amountIn) TSD.approve(address(pool), type(uint256).max);

        pool.provideToSP(amountIn, address(0));

        amountOut = mintAmountOut(amountIn);
        _mint(to, amountOut);
    }

    function burn(address to, uint256 amountIn) external returns (uint256 amountOut) {

        if (reinvestOnInteraction) reinvest();

        _burn(msg.sender, amountIn);
        amountOut = burnAmountOut(amountIn);
        SafeTransferLib.safeTransfer(TSD, to, amountOut);
    }

    function reinvest() public returns (uint256) {
        require(msg.sender == tx.origin || msg.sender == address(this), "sender must be EOA, or this contract");

        (uint256 TEDDYBal, uint256 amountOut, address router, address[] memory path) = pending();

        if (TEDDYBal > threshold) {
            uint256[] memory amountsOut = IUniswapV2Router02(router).swapExactTokensForTokens(TEDDYBal, 0, path, address(this), block.timestamp);

            uint256 totalProfit = amountsOut[amountsOut.length - 1];

            uint256 reinvestFee = totalProfit * REINVEST_FEE / DIVISOR;
            uint256 performanceFee = totalProfit * PERFORMANCE_FEE / DIVISOR;

            cummulativeProfit += totalProfit - reinvestFee - performanceFee;

            totalFeeBalances += reinvestFee + performanceFee;

            feeBalanceOf[admin] += performanceFee;
            feeBalanceOf[tx.origin] += reinvestFee; 
        }
    }

    ///////////////////////////////////////////////////////
    //////////////////////  PUBLIC VIEW ///////////////////
    ///////////////////////////////////////////////////////

    // function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function pending() public returns (uint256 TEDDYBal, uint256 amountOut, address router, address[] memory path) {

        TEDDYBal = TEDDY.balanceOf(address(this));

        path = new address[](3);
        
        path[1] = address(TEDDY);
        path[2] = address(WAVAX);
        path[2] = address(TSD);

        uint256[] memory amountsOutJoe = JOE_ROUTER.getAmountsOut(TEDDYBal, path);
        uint256[] memory amountsOutPango = PANGO_ROUTER.getAmountsOut(TEDDYBal, path);

        uint256 amountOutJoe = amountsOutJoe[amountsOutJoe.length - 1];
        uint256 amountOutPango = amountsOutPango[amountsOutPango.length - 1];

        amountOut = amountOutJoe < amountOutPango ? amountOutJoe : amountOutPango;
        router = amountOutJoe < amountOutPango ? address(JOE_ROUTER) : address(PANGO_ROUTER);

        return (TEDDYBal, amountOut, address(router), path);
    }

    function collectFees(address to) external returns (uint256 amountOut) {

        amountOut = feeBalanceOf[msg.sender];

        feeBalanceOf[msg.sender] = 0;

        totalFeeBalances -= amountOut;

        SafeTransferLib.safeTransfer(TSD, to, amountOut);
    }

    function mintAmountOut(uint256 amountIn) public view returns (uint256) {
        return amountIn * backing() / totalSupply;
    }

    function burnAmountOut(uint256 amountIn) public view returns (uint256) {
        return amountIn * totalSupply / backing();
    }

    function backing() public view returns (uint256) {
        return TSD.balanceOf(address(this)) - totalFeeBalances;
    }
}
