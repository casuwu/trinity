
const { MerkleTree } = require('merkletreejs');
const SHA256 = require('crypto-js/sha256');

const leaves = ['a', 'x', 'c'].map(x => SHA256(x));
const tree = new MerkleTree(leaves, SHA256);
const root = tree.getRoot().toString('hex');
const leaf = SHA256('a');
const proof = tree.getProof(leaf);
console.log(tree.verify(proof, leaf, root)) // true

const badLeaves = ['a', 'x', 'c'].map(x => SHA256(x));
const badTree = new MerkleTree(badLeaves, SHA256);
const badLeaf = SHA256('x');
const badProof = tree.getProof(badLeaf);
console.log(tree.verify(badProof, leaf, root)) // false

function csvToJSON(csv) {
    var lines = csv.split("\n");
    var result = [];
    var headers;
    headers = lines[0].split(",");

    for (var i = 1; i < lines.length; i++) {
        var obj = {};

        if(lines[i] == undefined || lines[i].trim() == "") {
            continue;
        }

        var words = lines[i].split(",");
        for(var j = 0; j < words.length; j++) {
            obj[headers[j].trim()] = words[j];
        }

        result.push(obj);
    }
    console.log(result);
}
