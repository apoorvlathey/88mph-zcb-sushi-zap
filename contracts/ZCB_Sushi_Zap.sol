// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address);
}

interface IUniswapV2Router02 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );
}

interface IUniswapV2Pair {
    function token0() external pure returns (address);

    function token1() external pure returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        );
}

interface IDInterest {
    function deposit(uint256 amount, uint256 maturationTimestamp) external;

    function depositsLength() external view returns (uint256);

    function depositNFT() external view returns (address);

    function getDeposit(uint256 depositID)
        external
        view
        returns (Deposit memory);

    struct Deposit {
        uint256 amount; // Amount of stablecoin deposited
        uint256 maturationTimestamp; // Unix timestamp after which the deposit may be withdrawn, in seconds
        uint256 interestOwed; // Deficit incurred to the pool at time of deposit
        uint256 initialMoneyMarketIncomeIndex; // Money market's income index at time of deposit
        bool active; // True if not yet withdrawn, false if withdrawn
        bool finalSurplusIsNegative;
        uint256 finalSurplusAmount; // Surplus remaining after withdrawal
        uint256 mintMPHAmount; // Amount of MPH minted to user
        uint256 depositTimestamp; // Unix timestamp at time of deposit, in seconds
    }
}

interface IZCB {
    function mintWithDepositNFT(
        uint256 nftID,
        string calldata fractionalDepositName,
        string calldata fractionalDepositSymbol
    )
        external
        returns (uint256 zeroCouponBondsAmount, address fractionalDeposit);
}

interface IFractionalDeposit {
    function transferOwnership(address newOwner) external;
}

contract ZCB_Sushi_Zap is ERC721Holder {
    using SafeERC20 for IERC20;

    IERC20 public constant MPH =
        IERC20(0x8888801aF4d980682e47f1A9036e589479e835C5);

    IUniswapV2Factory private constant sushiswapFactory =
        IUniswapV2Factory(0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac);
    IUniswapV2Router02 private constant sushiswapRouter =
        IUniswapV2Router02(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    function Zap(
        address fromToken,
        uint256 amountIn,
        address DInterest,
        uint256 maturationTimestamp,
        address ZCB
    ) external returns (uint256 lpReceived) {
        // get fromTokens from user
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        // get sushiswap pool for fromToken/ZCB pair
        address sushiPool = sushiswapFactory.getPair(fromToken, ZCB);

        uint256 amtToDepositInFIRB = _calcFIRBDepositAmt(
            fromToken,
            amountIn,
            sushiPool
        );
        uint256 fromTokensToDepositToSushi = amountIn - amtToDepositInFIRB;

        uint256 ZCBMinted = _mintZCBWithFromToken(
            fromToken,
            amtToDepositInFIRB,
            ZCB,
            DInterest,
            maturationTimestamp
        );

        lpReceived = _depositToSushi(
            fromToken,
            fromTokensToDepositToSushi,
            ZCB,
            ZCBMinted
        );
    }

    function _calcFIRBDepositAmt(
        address fromToken,
        uint256 amountIn,
        address sushiPool
    ) internal view returns (uint256 amtToDepositInFIRB) {
        // get reserves of sushiswap pool
        (uint256 res0, uint256 res1, ) = IUniswapV2Pair(sushiPool)
            .getReserves();

        // calculate amt to deposit into FIRB
        address token0 = IUniswapV2Pair(sushiPool).token0();
        if (fromToken == token0) {
            amtToDepositInFIRB = (res1 * amountIn - res0) / (res0 + res1);
        } else {
            amtToDepositInFIRB = (res0 * amountIn - res1) / (res0 + res1);
        }
    }

    function _mintZCBWithFromToken(
        address fromToken,
        uint256 amtToDepositInFIRB,
        address ZCB,
        address DInterest,
        uint256 maturationTimestamp
    ) internal returns (uint256 ZCBMinted) {
        // approve FIRB to spend fromTokens
        _approve(fromToken, address(DInterest), amtToDepositInFIRB);

        /// deposit fromTokens into FIRB
        // get NFT
        // MPH rewards gets vested
        IDInterest(DInterest).deposit(amtToDepositInFIRB, maturationTimestamp);
        uint256 nftID = IDInterest(DInterest).depositsLength();
        IDInterest.Deposit memory depositStruct = IDInterest(DInterest)
            .getDeposit(nftID);
        uint256 mphRequired = depositStruct.mintMPHAmount;
        // get MPH from user
        MPH.safeTransferFrom(msg.sender, address(this), mphRequired);

        // approve ZCB to spend NFT
        address depositNFT = IDInterest(DInterest).depositNFT();
        IERC721(depositNFT).setApprovalForAll(ZCB, true);
        // approve ZCB to spend MPH
        _approve(address(MPH), ZCB, mphRequired);

        // deposit NFT + MPH to ZCB
        address fractionalDepositAddress;
        (ZCBMinted, fractionalDepositAddress) = IZCB(ZCB).mintWithDepositNFT(
            nftID,
            "88mph Fractional Deposit",
            "88MPH-FD"
        );

        // transfer all fractionalDeposit tokens to msg.sender
        IERC20(fractionalDepositAddress).safeTransfer(
            msg.sender,
            IERC20(fractionalDepositAddress).balanceOf(address(this))
        );
        // transferOwnership of this fractionalDeposit to msg.sender
        IFractionalDeposit(fractionalDepositAddress).transferOwnership(
            msg.sender
        );
    }

    function _depositToSushi(
        address fromToken,
        uint256 fromTokensToDepositToSushi,
        address ZCB,
        uint256 ZCBMinted
    ) internal returns (uint256 lpReceived) {
        // approve sushiswapRouter to spend remaining fromTokens
        _approve(
            fromToken,
            address(sushiswapRouter),
            fromTokensToDepositToSushi
        );
        // approve sushiswapRouter to spend minted ZCB
        _approve(ZCB, address(sushiswapRouter), ZCBMinted);

        // deposit into sushipool, send SLP to msg.sender
        (, , lpReceived) = sushiswapRouter.addLiquidity(
            fromToken,
            ZCB,
            fromTokensToDepositToSushi,
            ZCBMinted,
            0,
            0,
            msg.sender,
            block.timestamp
        );

        // check for residue
        uint256 fromTokenResidue = IERC20(fromToken).balanceOf(address(this));
        uint256 zcbResidue = IERC20(ZCB).balanceOf(address(this));
        // transfer residue (if any)
        if (fromTokenResidue > 0) {
            IERC20(fromToken).safeTransfer(msg.sender, fromTokenResidue);
        }
        if (zcbResidue > 0) {
            IERC20(ZCB).safeTransfer(msg.sender, zcbResidue);
        }
    }

    function _approve(
        address token,
        address spender,
        uint256 amount
    ) internal {
        IERC20(token).safeApprove(spender, 0);
        IERC20(token).safeApprove(spender, amount);
    }
}
